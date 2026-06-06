#!/usr/bin/env python3
"""Guangzhou whitelist agent backed by an isolated nftables forwarding gate.

The agent does not modify existing DNAT/MASQUERADE rules. It owns only one
nftables table and refreshes that table from a tiny state file.
"""

from __future__ import annotations

import ipaddress
import json
import logging
import os
import signal
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit


def env_bool(name: str, default: str) -> bool:
    return os.environ.get(name, default).lower() in {"1", "true", "yes", "on"}


HOST = os.environ.get("GZ_AGENT_HOST", "127.0.0.1")
PORT = int(os.environ.get("GZ_AGENT_PORT", "9001"))
AGENT_TOKEN = os.environ.get("GZ_AGENT_TOKEN", "")
PUBLIC_INTERFACE = os.environ.get("PUBLIC_INTERFACE", "auto").strip()
PROTECT_TCP = env_bool("PROTECT_TCP", "true")
PROTECT_UDP = env_bool("PROTECT_UDP", "true")
FIREWALL_ENABLED = env_bool("FIREWALL_ENABLED", "true")
DEBUG_ENDPOINTS = env_bool("DEBUG_ENDPOINTS", "false")
MAX_IPS = int(os.environ.get("ALLOWLIST_MAX_IPS", "6"))
TTL_SECONDS = int(os.environ.get("ALLOWLIST_TTL_SECONDS", "86400"))
STATE_PATH = Path(os.environ.get("ALLOWLIST_STATE", "/var/lib/dynamic-whitelist/state.json"))
NFT = os.environ.get("NFT_BIN", "nft")
NFT_FAMILY = os.environ.get("NFT_FAMILY", "inet")
NFT_TABLE = os.environ.get("NFT_TABLE", "dynamic_whitelist")
NFT_SET = os.environ.get("NFT_ALLOW_SET", "allow4")
NFT_CHAIN = os.environ.get("NFT_CHAIN", "forward_guard")
NFT_PRIORITY = int(os.environ.get("NFT_PRIORITY", "-150"))
RECONCILE_INTERVAL = int(os.environ.get("RECONCILE_INTERVAL_SECONDS", "300"))

state_lock = threading.Lock()
stop_event = threading.Event()
STARTED_AT = int(time.time())


def run(args: list[str], check: bool = True, input_text: str | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, check=check, text=True, capture_output=True, input=input_text)


def is_public_ipv4(ip: str) -> bool:
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return addr.version == 4 and addr.is_global


def load_state() -> dict[str, Any]:
    try:
        with STATE_PATH.open("r", encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        return {"ips": {}}
    except json.JSONDecodeError:
        logging.warning("state file is invalid, starting with empty state")
        return {"ips": {}}
    if not isinstance(data, dict) or not isinstance(data.get("ips"), dict):
        return {"ips": {}}
    return data


def save_state(state: dict[str, Any]) -> None:
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=".state.", suffix=".json", dir=str(STATE_PATH.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(state, fh, separators=(",", ":"), sort_keys=True)
            fh.write("\n")
        os.replace(tmp_name, STATE_PATH)
    finally:
        if os.path.exists(tmp_name):
            os.unlink(tmp_name)


def detect_default_interface() -> str:
    try:
        with open("/proc/net/route", "r", encoding="utf-8") as fh:
            next(fh, None)
            for line in fh:
                fields = line.split()
                if len(fields) >= 4 and fields[1] == "00000000" and int(fields[3], 16) & 2:
                    return fields[0]
    except OSError:
        return ""
    return ""


def resolved_public_interface() -> str:
    value = PUBLIC_INTERFACE.lower()
    if value in {"", "auto"}:
        iface = detect_default_interface()
        if not iface:
            raise RuntimeError("PUBLIC_INTERFACE=auto but default interface could not be detected")
        return iface
    if value in {"all", "*"}:
        return ""
    return PUBLIC_INTERFACE


def nft_string(value: str) -> str:
    return json.dumps(value)


def nft_source_elements(active_ips: list[str]) -> str:
    if not active_ips:
        return ""
    return "        elements = { " + ", ".join(active_ips) + " }\n"


def build_ruleset(active_ips: list[str]) -> str:
    iface = resolved_public_interface()
    iif = f"iifname {nft_string(iface)} " if iface else ""
    source_elements = nft_source_elements(active_ips)
    lines = [
        f"table {NFT_FAMILY} {NFT_TABLE} {{",
        f"    set {NFT_SET} {{",
        "        type ipv4_addr",
        source_elements.rstrip("\n"),
        "    }",
        "",
        f"    chain {NFT_CHAIN} {{",
        f"        type filter hook forward priority {NFT_PRIORITY}; policy accept;",
        f"        {iif}ct state established,related accept",
        f"        {iif}ip saddr @{NFT_SET} accept",
    ]

    if PROTECT_TCP:
        lines.append(f"        {iif}tcp reject with tcp reset")
    if PROTECT_UDP:
        lines.append(f"        {iif}udp drop")

    lines.extend(["    }", "}", ""])
    return "\n".join(line for line in lines if line != "")


def disable_owned_table() -> None:
    try:
        run([NFT, "delete", "table", NFT_FAMILY, NFT_TABLE], check=False)
    except FileNotFoundError:
        logging.warning("nft binary not found while disabling owned table")


def apply_ruleset(active_ips: list[str]) -> None:
    if not FIREWALL_ENABLED:
        disable_owned_table()
        logging.info("firewall disabled; skipped nft apply active=%s", len(active_ips))
        return

    ruleset = build_ruleset(active_ips)
    run([NFT, "delete", "table", NFT_FAMILY, NFT_TABLE], check=False)
    run([NFT, "-f", "-"], input_text=ruleset)


def active_ips_from_state(state: dict[str, Any], now: int | None = None) -> list[str]:
    now = int(time.time()) if now is None else now
    ips: dict[str, Any] = state.setdefault("ips", {})
    return sorted(
        [addr for addr, meta in ips.items() if int(meta.get("expires_at", 0)) > now],
        key=lambda addr: int(ips[addr].get("last_seen", 0)),
        reverse=True,
    )


def firewall_status() -> dict[str, Any]:
    iface_status: dict[str, Any]
    try:
        iface_status = {"value": resolved_public_interface() or "<all>"}
    except Exception as exc:  # noqa: BLE001
        iface_status = {"error": str(exc)}
    return {
        "role": "gz-agent",
        "enabled": FIREWALL_ENABLED,
        "mode": "enforce" if FIREWALL_ENABLED else "debug_disabled",
        "uptime_seconds": int(time.time()) - STARTED_AT,
        "debug_endpoints": DEBUG_ENDPOINTS,
        "public_interface": iface_status,
        "nft": {
            "family": NFT_FAMILY,
            "table": NFT_TABLE,
            "set": NFT_SET,
            "chain": NFT_CHAIN,
            "priority": NFT_PRIORITY,
        },
    }


def state_snapshot() -> dict[str, Any]:
    now = int(time.time())
    state = load_state()
    ips: dict[str, Any] = state.setdefault("ips", {})
    active = active_ips_from_state(state, now)
    entries = []
    for ip in active:
        meta = ips[ip]
        expires_at = int(meta.get("expires_at", 0))
        entries.append(
            {
                "ip": ip,
                "device": str(meta.get("device", "")),
                "first_seen": int(meta.get("first_seen", 0)),
                "last_seen": int(meta.get("last_seen", 0)),
                "expires_at": expires_at,
                "ttl_remaining": max(0, expires_at - now),
                "count": int(meta.get("count", 0)),
            }
        )
    expired_count = len([addr for addr, meta in ips.items() if int(meta.get("expires_at", 0)) <= now])
    return {
        "ok": True,
        "firewall": firewall_status(),
        "state_path": str(STATE_PATH),
        "ttl": TTL_SECONDS,
        "max_ips": MAX_IPS,
        "protect_tcp": PROTECT_TCP,
        "protect_udp": PROTECT_UDP,
        "reconcile_interval": RECONCILE_INTERVAL,
        "count": len(entries),
        "expired_count": expired_count,
        "active": entries,
    }


def refresh_ip(ip: str, device: str) -> dict[str, Any]:
    if not is_public_ipv4(ip):
        raise ValueError("ip must be a public IPv4 address")

    now = int(time.time())
    with state_lock:
        state = load_state()
        ips: dict[str, Any] = state.setdefault("ips", {})

        expired = [addr for addr, meta in ips.items() if int(meta.get("expires_at", 0)) <= now]
        for addr in expired:
            ips.pop(addr, None)

        evicted = None
        if ip not in ips and len(ips) >= MAX_IPS:
            evicted = min(ips.items(), key=lambda item: int(item[1].get("last_seen", 0)))[0]
            ips.pop(evicted, None)

        meta = ips.get(ip, {})
        first_seen = int(meta.get("first_seen", now))
        ips[ip] = {
            "device": device,
            "first_seen": first_seen,
            "last_seen": now,
            "expires_at": now + TTL_SECONDS,
            "count": int(meta.get("count", 0)) + 1,
        }

        active = active_ips_from_state(state, now)
        apply_ruleset(active)
        save_state(state)

    return {
        "ip": ip,
        "active": active,
        "count": len(active),
        "ttl": TTL_SECONDS,
        "expires_at": now + TTL_SECONDS,
        "evicted": evicted,
        "expired": expired,
        "firewall": firewall_status(),
    }


def reconcile_state() -> dict[str, Any]:
    now = int(time.time())
    with state_lock:
        state = load_state()
        ips: dict[str, Any] = state.setdefault("ips", {})
        expired = [addr for addr, meta in ips.items() if int(meta.get("expires_at", 0)) <= now]
        for addr in expired:
            ips.pop(addr, None)
        active = active_ips_from_state(state, now)
        apply_ruleset(active)
        save_state(state)
    return {"active": active, "expired": expired, "count": len(active), "firewall": firewall_status()}


def reconcile_loop() -> None:
    while not stop_event.wait(RECONCILE_INTERVAL):
        try:
            result = reconcile_state()
            logging.info("reconciled active=%s expired=%s", result["count"], len(result["expired"]))
        except Exception as exc:  # noqa: BLE001
            logging.warning("reconcile failed: %s", exc)


def json_response(handler: BaseHTTPRequestHandler, code: int, data: dict[str, Any]) -> None:
    body = json.dumps(data, separators=(",", ":")).encode("utf-8")
    handler.send_response(code)
    handler.send_header("content-type", "application/json; charset=utf-8")
    handler.send_header("cache-control", "no-store")
    handler.send_header("content-length", str(len(body)))
    handler.end_headers()
    if handler.command != "HEAD":
        handler.wfile.write(body)


def authorized(handler: BaseHTTPRequestHandler) -> bool:
    return bool(AGENT_TOKEN) and handler.headers.get("x-agent-token") == AGENT_TOKEN


class Handler(BaseHTTPRequestHandler):
    server_version = "GZWhitelistAgent/1.0"

    def log_message(self, fmt: str, *args: Any) -> None:
        logging.info("%s - %s", self.address_string(), fmt % args)

    def do_GET(self) -> None:
        path = urlsplit(self.path).path
        if path == "/healthz":
            json_response(self, 200, {"ok": True, "role": "gz-agent", "firewall": firewall_status(), "state_path": str(STATE_PATH), "uptime_seconds": int(time.time()) - STARTED_AT})
            return
        if path.startswith("/debug/"):
            self.handle_debug_get(path)
            return
        json_response(self, 404, {"ok": False, "error": "not_found"})

    def do_POST(self) -> None:
        path = urlsplit(self.path).path
        if path.startswith("/debug/"):
            self.handle_debug_post(path)
            return
        if path != "/v1/allow":
            json_response(self, 404, {"ok": False, "error": "not_found"})
            return
        if not authorized(self):
            json_response(self, 403, {"ok": False, "error": "forbidden"})
            return
        try:
            length = int(self.headers.get("content-length", "0"))
            raw = self.rfile.read(min(length, 4096))
            payload = json.loads(raw.decode("utf-8"))
            ip = str(payload.get("ip", ""))
            device = str(payload.get("device", "default"))[:64]
            result = refresh_ip(ip, device)
        except ValueError as exc:
            json_response(self, 400, {"ok": False, "error": str(exc)})
            return
        except subprocess.CalledProcessError as exc:
            logging.error("nft failed: %s stderr=%s", exc.cmd, exc.stderr)
            json_response(self, 500, {"ok": False, "error": "nft_failed", "detail": exc.stderr})
            return
        except Exception as exc:  # noqa: BLE001
            logging.exception("request failed")
            json_response(self, 500, {"ok": False, "error": "internal_error", "detail": str(exc)})
            return
        logging.info("refreshed ip=%s active=%s firewall=%s", result["ip"], result["count"], result["firewall"]["mode"])
        json_response(self, 200, {"ok": True, **result})

    def check_debug(self) -> bool:
        if not DEBUG_ENDPOINTS:
            json_response(self, 404, {"ok": False, "error": "debug_disabled"})
            return False
        if not authorized(self):
            json_response(self, 403, {"ok": False, "error": "forbidden"})
            return False
        return True

    def handle_debug_get(self, path: str) -> None:
        if not self.check_debug():
            return
        if path == "/debug/state":
            json_response(self, 200, state_snapshot())
            return
        if path == "/debug/ruleset":
            state = load_state()
            active = active_ips_from_state(state)
            try:
                ruleset = build_ruleset(active)
            except Exception as exc:  # noqa: BLE001
                json_response(self, 500, {"ok": False, "error": "ruleset_preview_failed", "detail": str(exc)})
                return
            json_response(self, 200, {"ok": True, "firewall": firewall_status(), "active": active, "ruleset": ruleset})
            return
        json_response(self, 404, {"ok": False, "error": "not_found"})

    def handle_debug_post(self, path: str) -> None:
        if not self.check_debug():
            return
        if path == "/debug/reconcile":
            try:
                result = reconcile_state()
            except subprocess.CalledProcessError as exc:
                json_response(self, 500, {"ok": False, "error": "nft_failed", "detail": exc.stderr})
                return
            json_response(self, 200, {"ok": True, **result})
            return
        json_response(self, 404, {"ok": False, "error": "not_found"})


def main() -> None:
    if not AGENT_TOKEN:
        raise SystemExit("GZ_AGENT_TOKEN is required")
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    reconcile_state()
    threading.Thread(target=reconcile_loop, name="nft-reconciler", daemon=True).start()

    httpd = ThreadingHTTPServer((HOST, PORT), Handler)
    httpd.timeout = 1.0
    signal.signal(signal.SIGTERM, lambda _signum, _frame: stop_event.set())
    logging.info(
        "listening on %s:%s, public_interface=%s, protect_tcp=%s, protect_udp=%s, firewall=%s, debug=%s, nft=%s/%s",
        HOST,
        PORT,
        firewall_status()["public_interface"],
        PROTECT_TCP,
        PROTECT_UDP,
        firewall_status()["mode"],
        DEBUG_ENDPOINTS,
        NFT_FAMILY,
        NFT_TABLE,
    )
    while not stop_event.is_set():
        httpd.handle_request()


if __name__ == "__main__":
    main()
