#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="/opt/dynamic-whitelist/hk-relay"
ENV_DIR="/etc/dynamic-whitelist"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required." >&2
  exit 1
fi

id -u dynamicwl >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin dynamicwl

install -d -m 0755 "$APP_DIR" "$ENV_DIR"
install -m 0755 "$SRC_DIR/hk-relay/hk_relay.py" "$APP_DIR/hk_relay.py"

if [[ ! -f "$ENV_DIR/hk-relay.env" ]]; then
  install -m 0600 "$SRC_DIR/env/hk-relay.env.example" "$ENV_DIR/hk-relay.env"
  echo "Created $ENV_DIR/hk-relay.env. Edit tokens and GZ_AGENT_URL before starting."
fi

install -m 0644 "$SRC_DIR/systemd/hk-relay.service" /etc/systemd/system/hk-relay.service
systemctl daemon-reload
systemctl enable hk-relay.service

echo "Installed hk-relay. Start it after editing $ENV_DIR/hk-relay.env:"
echo "  systemctl start hk-relay"

