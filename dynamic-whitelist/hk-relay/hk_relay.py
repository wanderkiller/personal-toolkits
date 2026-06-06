#!/usr/bin/env python3
"""Hong Kong relay for dynamic whitelist updates.

This service receives accepted client IPs from Alibaba Cloud FC and forwards
them over the CCN private network to the Guangzhou whitelist agent.
"""

from __future__ import annotations

import json
import logging
import os
import queue
import signal
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any


def env_bool(name: str, default: str) -> bool:
    return os.environ.get(name, default).lower() in {"1", "true", "yes", "on"}


HOST = os.environ.get("HK_RELAY_HOST", "0.0.0.0")
PORT = int(os.environ.get("HK_RELAY_PORT", "9000"))
RELAY_TOKEN = os.environ.get("RELAY_TOKEN", "")
GZ_AGENT_URL = os.environ.get("GZ_AGENT_URL", "http://127.0.0.1:9001/v1/allow")
GZ_AGENT_TOKEN = os.environ.get("GZ_AGENT_TOKEN", "")
GZ_AGENT_TIMEOUT = float(os.environ.get("GZ_AGENT_TIMEOUT", "2.0"))
QUEUE_MAX = int(os.environ.get("HK_RELAY_QUEUE_MAX", "256"))
FORWARD_RETRIES = int(os.environ.get("HK_RELAY_FORWARD_RETRIES", "3"))
FORWARD_RETRY_DELAY = float(os.environ.get("HK_RELAY_FORWARD_RETRY_DELAY", "0.5"))
DEBUG_ENDPOINTS = env_bool("HK_RELAY_DEBUG_ENDPOINTS", "false")

work_queue: queue.Queue[dict[str, Any]] = queue.Queue(maxsize=QUEUE_MAX)
stop_event = threading.Event()
STARTED_AT = int(time.time())


def json_response(handler: BaseHTTPRequestHandler, code: int, data: dict[str, Any]) -> None:
    body = json.dumps(data, separators=(",", ":")).encode("utf-8")
    handler.send_response(code)
    handler.send_header("content-type", "application/json; charset=utf-8")
    handler.send_header("cache-control", "no-store")
    handler.send_header("content-length", str(len(body)))
    handler.end_headers()
    if handler.command != "HEAD":
        handler.wfile.write(body)


def is_ipv4(ip: str) -> bool:
    parts = ip.split(".")
    if len(parts) != 4:
        return False
    try:
        nums = [int(part) for part in parts]
    except ValueError:
        return False
    return all(str(num) == part and 0 <= num <= 255 for num, part in zip(nums, parts))


def decode_response(resp: Any) -> dict[str, Any]:
    text = resp.read().decode("utf-8", "replace")
    try:
        data = json.loads(text) if text else {}
    except json.JSONDecodeError:
        data = {"raw": text}
    return {"status": resp.status, "body": data}


def decode_http_error(exc: urllib.error.HTTPError) -> dict[str, Any]:
    text = exc.read().decode("utf-8", "replace")
    try:
        body = json.loads(text) if text else {}
    except json.JSONDecodeError:
        body = {"raw": text}
    return {"status": exc.code, "body": body}


def gz_agent_base_url() -> str:
    parsed = urllib.parse.urlsplit(GZ_AGENT_URL)
    path = parsed.path
    if path.endswith("/v1/allow"):
        path = path[: -len("/v1/allow")]
    else:
        path = path.rstrip("/")
    return urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, path.rstrip("/"), "", ""))


def request_gz(method: str, path: str, payload: dict[str, Any] | None = None) -> dict[str, Any]:
    body = json.dumps(payload, separators=(",", ":")).encode("utf-8") if payload is not None else None
    headers = {"x-agent-token": GZ_AGENT_TOKEN}
    if body is not None:
        headers["content-type"] = "application/json"
    req = urllib.request.Request(
        gz_agent_base_url() + path,
        data=body,
        method=method,
        headers=headers,
    )
    with urllib.request.urlopen(req, timeout=GZ_AGENT_TIMEOUT) as resp:
        return decode_response(resp)


def forward_to_gz(payload: dict[str, Any]) -> dict[str, Any]:
    body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    req = urllib.request.Request(
        GZ_AGENT_URL,
        data=body,
        method="POST",
        headers={
            "content-type": "application/json",
            "x-agent-token": GZ_AGENT_TOKEN,
        },
    )
    with urllib.request.urlopen(req, timeout=GZ_AGENT_TIMEOUT) as resp:
        return decode_response(resp)


def worker() -> None:
    while not stop_event.is_set():
        try:
            payload = work_queue.get(timeout=0.5)
        except queue.Empty:
            continue
        try:
            last_error = None
            for attempt in range(1, FORWARD_RETRIES + 1):
                try:
                    result = forward_to_gz(payload)
                    logging.info("forwarded ip=%s status=%s attempt=%s", payload.get("ip"), result["status"], attempt)
                    break
                except Exception as exc:  # noqa: BLE001 - retry transient network failures.
                    last_error = exc
                    logging.warning("forward failed ip=%s attempt=%s/%s error=%s", payload.get("ip"), attempt, FORWARD_RETRIES, exc)
                    if attempt < FORWARD_RETRIES:
                        time.sleep(FORWARD_RETRY_DELAY * attempt)
            else:
                logging.error("dropping ip=%s after %s attempts error=%s", payload.get("ip"), FORWARD_RETRIES, last_error)
        finally:
            work_queue.task_done()


def authorized(handler: BaseHTTPRequestHandler) -> bool:
    return bool(RELAY_TOKEN) and handler.headers.get("x-relay-token") == RELAY_TOKEN


class Handler(BaseHTTPRequestHandler):
    server_version = "HKRelay/1.0"

    def log_message(self, fmt: str, *args: Any) -> None:
        logging.info("%s - %s", self.address_string(), fmt % args)

    def do_GET(self) -> None:
        path = urllib.parse.urlsplit(self.path).path
        if path == "/healthz":
            json_response(self, 200, {"ok": True, "role": "hk-relay", "queue": work_queue.qsize(), "queue_capacity": QUEUE_MAX, "debug_endpoints": DEBUG_ENDPOINTS, "uptime_seconds": int(time.time()) - STARTED_AT})
            return
        if path.startswith("/debug/"):
            self.handle_debug_get(path)
            return
        json_response(self, 404, {"ok": False, "error": "not_found"})

    def do_POST(self) -> None:
        path = urllib.parse.urlsplit(self.path).path
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
        except Exception:
            json_response(self, 400, {"ok": False, "error": "invalid_json"})
            return

        ip = str(payload.get("ip", ""))
        if not is_ipv4(ip):
            json_response(self, 400, {"ok": False, "error": "invalid_ip"})
            return

        job = {
            "ip": ip,
            "device": str(payload.get("device", "default"))[:64],
            "ts": int(time.time()),
        }
        mode = payload.get("mode")

        if mode == "wait":
            try:
                result = forward_to_gz(job)
            except urllib.error.HTTPError as exc:
                gz_error = decode_http_error(exc)
                logging.warning("wait forward got gz_http_error status=%s body=%s", gz_error["status"], gz_error["body"])
                json_response(self, 502, {"ok": False, "error": "gz_http_error", "gz": gz_error})
                return
            except Exception as exc:  # noqa: BLE001
                json_response(self, 504, {"ok": False, "error": "gz_forward_failed", "detail": str(exc)})
                return
            ok = 200 <= result["status"] < 300
            json_response(self, 200 if ok else 502, {"ok": ok, "gz": result})
            return

        try:
            work_queue.put_nowait(job)
        except queue.Full:
            json_response(self, 503, {"ok": False, "error": "queue_full"})
            return
        json_response(self, 202, {"ok": True, "accepted": True, "queue": work_queue.qsize()})

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
        if path == "/debug/status":
            try:
                gz_health = request_gz("GET", "/healthz")
            except Exception as exc:  # noqa: BLE001
                gz_health = {"status": 0, "body": {"ok": False, "error": str(exc)}}
            json_response(
                self,
                200,
                {
                    "ok": True,
                    "debug_endpoints": DEBUG_ENDPOINTS,
                    "queue": work_queue.qsize(),
                    "queue_capacity": QUEUE_MAX,
                    "forward_retries": FORWARD_RETRIES,
                    "forward_retry_delay": FORWARD_RETRY_DELAY,
                    "gz_agent_url": GZ_AGENT_URL,
                    "gz_agent_base_url": gz_agent_base_url(),
                    "gz_agent_timeout": GZ_AGENT_TIMEOUT,
                    "uptime_seconds": int(time.time()) - STARTED_AT,
                    "gz_health": gz_health,
                },
            )
            return
        if path == "/debug/gz/state":
            self.proxy_debug("GET", "/debug/state")
            return
        if path == "/debug/gz/ruleset":
            self.proxy_debug("GET", "/debug/ruleset")
            return
        json_response(self, 404, {"ok": False, "error": "not_found"})

    def handle_debug_post(self, path: str) -> None:
        if not self.check_debug():
            return
        if path == "/debug/gz/reconcile":
            self.proxy_debug("POST", "/debug/reconcile", {})
            return
        json_response(self, 404, {"ok": False, "error": "not_found"})

    def proxy_debug(self, method: str, path: str, payload: dict[str, Any] | None = None) -> None:
        try:
            result = request_gz(method, path, payload)
        except urllib.error.HTTPError as exc:
            text = exc.read().decode("utf-8", "replace")
            try:
                body = json.loads(text) if text else {}
            except json.JSONDecodeError:
                body = {"raw": text}
            json_response(self, 502, {"ok": False, "error": "gz_http_error", "gz": {"status": exc.code, "body": body}})
            return
        except Exception as exc:  # noqa: BLE001
            json_response(self, 504, {"ok": False, "error": "gz_debug_failed", "detail": str(exc)})
            return
        ok = 200 <= result["status"] < 300
        json_response(self, 200 if ok else 502, {"ok": ok, "gz": result})


def main() -> None:
    if not RELAY_TOKEN or not GZ_AGENT_TOKEN:
        raise SystemExit("RELAY_TOKEN and GZ_AGENT_TOKEN are required")
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    threading.Thread(target=worker, name="gz-forwarder", daemon=True).start()

    httpd = ThreadingHTTPServer((HOST, PORT), Handler)
    httpd.timeout = 1.0
    signal.signal(signal.SIGTERM, lambda _signum, _frame: stop_event.set())
    logging.info("listening on %s:%s debug=%s", HOST, PORT, DEBUG_ENDPOINTS)
    while not stop_event.is_set():
        httpd.handle_request()


if __name__ == "__main__":
    main()
