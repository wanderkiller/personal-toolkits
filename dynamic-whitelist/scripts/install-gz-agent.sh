#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="/opt/dynamic-whitelist/gz-agent"
ENV_DIR="/etc/dynamic-whitelist"
STATE_DIR="/var/lib/dynamic-whitelist"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required." >&2
  exit 1
fi

if ! command -v nft >/dev/null 2>&1; then
  echo "nftables is required." >&2
  exit 1
fi

install -d -m 0755 "$APP_DIR" "$ENV_DIR" "$STATE_DIR"
install -m 0755 "$SRC_DIR/gz-agent/gz_agent.py" "$APP_DIR/gz_agent.py"

if [[ ! -f "$ENV_DIR/gz-agent.env" ]]; then
  install -m 0600 "$SRC_DIR/env/gz-agent.env.example" "$ENV_DIR/gz-agent.env"
  echo "Created $ENV_DIR/gz-agent.env. Edit token, CCN bind IP, and PUBLIC_INTERFACE before starting."
fi

install -m 0644 "$SRC_DIR/systemd/gz-agent.service" /etc/systemd/system/gz-agent.service
systemctl daemon-reload
systemctl enable gz-agent.service

echo "Installed gz-agent. Start it after editing $ENV_DIR/gz-agent.env:"
echo "  systemctl start gz-agent"


