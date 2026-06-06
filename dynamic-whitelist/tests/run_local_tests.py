#!/usr/bin/env python3
from __future__ import annotations

import concurrent.futures
import importlib.util
import json
import os
import pathlib
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from types import ModuleType


ROOT = pathlib.Path(__file__).resolve().parents[1]


def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, cwd=ROOT, text=True, capture_output=True, check=True, **kwargs)

def find_bash() -> str | None:
    candidates: list[str] = []
    git_bash = pathlib.Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "Git" / "bin" / "bash.exe"
    candidates.append(str(git_bash))

    bash = shutil.which("bash")
    if bash:
        candidates.append(bash)

    for candidate in candidates:
        if not candidate or not pathlib.Path(candidate).exists():
            continue
        probe = subprocess.run([candidate, "--version"], text=True, capture_output=True, check=False)
        text = (probe.stdout + probe.stderr).lower()
        if probe.returncode == 0 and ("gnu bash" in text or "git" in text):
            return candidate
    return None

def load_module(name: str, rel: str, env: dict[str, str]) -> ModuleType:
    old = os.environ.copy()
    os.environ.update(env)
    try:
        spec = importlib.util.spec_from_file_location(name, ROOT / rel)
        if not spec or not spec.loader:
            raise RuntimeError(f"cannot load {rel}")
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        spec.loader.exec_module(module)
        return module
    finally:
        os.environ.clear()
        os.environ.update(old)


def test_static_checks() -> None:
    py_files = ["hk-relay/hk_relay.py", "gz-agent/gz_agent.py"]
    for rel in py_files:
        source = (ROOT / rel).read_text(encoding="utf-8")
        compile(source, rel, "exec")

    node = shutil.which("node")
    if node:
        run([node, "--check", str(ROOT / "fc/index.js")])
        run([node, str(ROOT / "tests/fc_test.js")])

    bash = find_bash()
    if bash:
        for rel in [
            "scripts/docker-up-gz.sh",
            "scripts/docker-up-hk.sh",
            "scripts/doctor.sh",
            "scripts/quick-start.sh",
            "scripts/deploy.sh",
            "scripts/install-gz-agent.sh",
            "scripts/install-hk-relay.sh",
            "scripts/package-release.sh",
        ]:
            run([bash, "-n", str(ROOT / rel)])


def test_gz_rule_order_and_lru() -> None:
    state = pathlib.Path(tempfile.gettempdir()) / f"dw-state-{os.getpid()}.json"
    state.unlink(missing_ok=True)
    module = load_module(
        "gz_agent_test",
        "gz-agent/gz_agent.py",
        {
            "GZ_AGENT_TOKEN": "agent",
            "GZ_AGENT_HOST": "127.0.0.1",
            "GZ_AGENT_PORT": "9001",
            "PUBLIC_INTERFACE": "eth0",
            "ALLOWLIST_STATE": str(state),
            "PROTECT_TCP": "true",
            "PROTECT_UDP": "true",
            "RECONCILE_INTERVAL_SECONDS": "9999",
        },
    )

    applied_rulesets: list[str] = []

    def fake_run(args: list[str], check: bool = True, input_text: str | None = None):
        if args == ["nft", "-f", "-"]:
            assert input_text is not None
            applied_rulesets.append(input_text)
        assert "nat" not in " ".join(args), args
        return type("Result", (), {"returncode": 0, "stderr": ""})()

    module.run = fake_run
    module.apply_ruleset([])
    ruleset = applied_rulesets[-1]
    assert "table inet dynamic_whitelist" in ruleset
    assert "type filter hook forward priority -150; policy accept;" in ruleset
    assert 'iifname "eth0" ct state established,related accept' in ruleset
    assert 'iifname "eth0" ip saddr @allow4 accept' in ruleset
    assert 'iifname "eth0" tcp reject with tcp reset' in ruleset
    assert 'iifname "eth0" udp drop' in ruleset
    assert "dnat" not in ruleset.lower()
    assert "masquerade" not in ruleset.lower()

    for i in range(1, 8):
        module.refresh_ip(f"8.8.8.{i}", "unit")
    data = module.load_state()
    ips = sorted(data["ips"])
    assert len(ips) == 6
    assert "8.8.8.1" not in ips
    assert "elements = {" in applied_rulesets[-1]

    before = data["ips"]["8.8.8.2"]["count"]
    module.refresh_ip("8.8.8.2", "unit")
    after = module.load_state()["ips"]["8.8.8.2"]["count"]
    assert after == before + 1


def test_gz_concurrency() -> None:
    state = pathlib.Path(tempfile.gettempdir()) / f"dw-concurrency-{os.getpid()}.json"
    state.unlink(missing_ok=True)
    module = load_module(
        "gz_agent_concurrency_test",
        "gz-agent/gz_agent.py",
        {
            "GZ_AGENT_TOKEN": "agent",
            "PUBLIC_INTERFACE": "eth0",
            "ALLOWLIST_STATE": str(state),
        },
    )
    module.run = lambda args, check=True, input_text=None: type("Result", (), {"returncode": 0, "stderr": ""})()

    ips = [f"8.8.4.{i}" for i in range(1, 21)]
    with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
        futures = [pool.submit(module.refresh_ip, ips[i % len(ips)], "stress") for i in range(250)]
        for future in futures:
            future.result(timeout=5)

    data = module.load_state()
    assert len(data["ips"]) <= 6
    assert all(meta["expires_at"] > int(time.time()) for meta in data["ips"].values())


def test_gz_debug_dry_run() -> None:
    state = pathlib.Path(tempfile.gettempdir()) / f"dw-debug-{os.getpid()}.json"
    state.unlink(missing_ok=True)
    module = load_module(
        "gz_agent_debug_test",
        "gz-agent/gz_agent.py",
        {
            "GZ_AGENT_TOKEN": "agent",
            "PUBLIC_INTERFACE": "eth0",
            "ALLOWLIST_STATE": str(state),
            "FIREWALL_ENABLED": "false",
            "DEBUG_ENDPOINTS": "true",
        },
    )

    calls: list[tuple[list[str], str | None]] = []

    def fake_run(args: list[str], check: bool = True, input_text: str | None = None):
        calls.append((args, input_text))
        return type("Result", (), {"returncode": 0, "stderr": ""})()

    module.run = fake_run
    result = module.refresh_ip("8.8.8.8", "debug")
    assert result["firewall"]["enabled"] is False
    assert result["firewall"]["mode"] == "debug_disabled"
    assert any(args[:4] == ["nft", "delete", "table", "inet"] for args, _ in calls)
    assert not any(args == ["nft", "-f", "-"] for args, _ in calls)

    snapshot = module.state_snapshot()
    assert snapshot["count"] == 1
    assert snapshot["firewall"]["debug_endpoints"] is True

    ruleset = module.build_ruleset(["8.8.8.8"])
    assert "table inet dynamic_whitelist" in ruleset
    assert "8.8.8.8" in ruleset
def test_hk_relay_wait_and_fast() -> None:
    received: "queue.Queue[dict]" = queue.Queue()

    class GzHandler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):  # noqa: ANN001
            return

        def do_GET(self):  # noqa: N802
            if self.path == "/healthz":
                body = b'{"ok":true,"from":"gz-health"}'
            elif self.path == "/debug/state":
                received.put({"token": self.headers.get("x-agent-token"), "debug_path": self.path})
                body = b'{"ok":true,"firewall":{"enabled":false,"mode":"debug_disabled"}}'
            elif self.path == "/debug/ruleset":
                body = b'{"ok":true,"ruleset":"preview"}'
            else:
                self.send_response(404)
                self.end_headers()
                return
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):  # noqa: N802
            length = int(self.headers.get("content-length", "0"))
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
            received.put({"token": self.headers.get("x-agent-token"), "payload": payload})
            body = b'{"ok":true}'
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    gz_server = ThreadingHTTPServer(("127.0.0.1", 0), GzHandler)
    gz_server.timeout = 1
    threading.Thread(target=gz_server.serve_forever, daemon=True).start()
    gz_port = gz_server.server_address[1]

    module = load_module(
        "hk_relay_test",
        "hk-relay/hk_relay.py",
        {
            "RELAY_TOKEN": "relay",
            "GZ_AGENT_TOKEN": "agent",
            "GZ_AGENT_URL": f"http://127.0.0.1:{gz_port}/v1/allow",
            "GZ_AGENT_TIMEOUT": "2",
            "HK_RELAY_DEBUG_ENDPOINTS": "true",
        },
    )
    threading.Thread(target=module.worker, daemon=True).start()
    relay_server = ThreadingHTTPServer(("127.0.0.1", 0), module.Handler)
    relay_server.timeout = 1
    threading.Thread(target=relay_server.serve_forever, daemon=True).start()
    relay_port = relay_server.server_address[1]

    def post(payload: dict) -> tuple[int, dict]:
        req = urllib.request.Request(
            f"http://127.0.0.1:{relay_port}/v1/allow",
            data=json.dumps(payload).encode("utf-8"),
            method="POST",
            headers={"content-type": "application/json", "x-relay-token": "relay"},
        )
        with urllib.request.urlopen(req, timeout=3) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))

    def get(path: str) -> tuple[int, dict]:
        req = urllib.request.Request(
            f"http://127.0.0.1:{relay_port}{path}",
            method="GET",
            headers={"x-relay-token": "relay"},
        )
        with urllib.request.urlopen(req, timeout=3) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))

    status, body = post({"ip": "8.8.8.8", "device": "wait", "mode": "wait"})
    assert status == 200 and body["ok"] is True
    assert received.get(timeout=2)["token"] == "agent"

    status, body = post({"ip": "8.8.4.4", "device": "fast", "mode": "fast"})
    assert status == 202 and body["accepted"] is True
    assert received.get(timeout=2)["payload"]["ip"] == "8.8.4.4"

    status, body = get("/debug/status")
    assert status == 200 and body["ok"] is True
    assert body["gz_health"]["body"]["from"] == "gz-health"

    status, body = get("/debug/gz/state")
    assert status == 200 and body["ok"] is True
    assert body["gz"]["body"]["firewall"]["enabled"] is False
    assert received.get(timeout=2)["debug_path"] == "/debug/state"

    module.stop_event.set()
    relay_server.shutdown()
    gz_server.shutdown()


def test_compose_contracts() -> None:
    gz = (ROOT / "docker-compose.gz.yml").read_text(encoding="utf-8")
    assert "network_mode: host" in gz
    assert "- NET_ADMIN" in gz
    assert "- /var/lib/dynamic-whitelist:/data" in gz
    assert "nftables" in (ROOT / "docker/gz-agent/Dockerfile").read_text(encoding="utf-8")

    hk = (ROOT / "docker-compose.hk.yml").read_text(encoding="utf-8")
    assert '"127.0.0.1:9000:9000"' in hk
    assert "HK_RELAY_HOST: 0.0.0.0" in hk


def main() -> None:
    tests = [
        test_static_checks,
        test_gz_rule_order_and_lru,
        test_gz_concurrency,
        test_gz_debug_dry_run,
        test_hk_relay_wait_and_fast,
        test_compose_contracts,
    ]
    for test in tests:
        test()
        print(f"{test.__name__}: ok")
    print("all local tests ok")


if __name__ == "__main__":
    main()

