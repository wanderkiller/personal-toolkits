#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DEBUG_MODE=false
if [[ "${1:-}" == "--debug" ]]; then
  DEBUG_MODE=true
elif [[ "${1:-}" != "" ]]; then
  echo "Usage: sudo bash scripts/docker-up-gz.sh [--debug]" >&2
  exit 1
fi

COMPOSE_FILES=(-f docker-compose.gz.yml)
if [[ "$DEBUG_MODE" == "true" ]]; then
  COMPOSE_FILES+=(-f docker-compose.gz.debug.yml)
fi
CONTAINER_NAME="dynamic-whitelist-gz-agent"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "$1 is required." >&2
    exit 1
  fi
}

need_cmd docker

if ! docker compose version >/dev/null 2>&1; then
  echo "docker compose plugin is required." >&2
  exit 1
fi

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root so Docker can start a NET_ADMIN host-network container." >&2
  exit 1
fi

if [[ ! -f env/gz-agent.env ]]; then
  cp env/gz-agent.env.example env/gz-agent.env
  echo "Created env/gz-agent.env. Edit token, CCN bind/source IPs, and PUBLIC_INTERFACE, then rerun this script." >&2
  exit 1
fi

compose_config="$(docker compose "${COMPOSE_FILES[@]}" config)"
if ! grep -q '^    network_mode: host$' <<<"$compose_config"; then
  echo "Refusing to start: gz-agent must use network_mode: host." >&2
  exit 1
fi
if ! grep -q '^      - NET_ADMIN$' <<<"$compose_config"; then
  echo "Refusing to start: gz-agent must include cap_add: NET_ADMIN." >&2
  exit 1
fi

mkdir -p /var/lib/dynamic-whitelist

docker compose "${COMPOSE_FILES[@]}" up -d --build

docker ps --filter "name=$CONTAINER_NAME"

if ! docker exec "$CONTAINER_NAME" nft list ruleset >/dev/null 2>&1; then
  echo "Container started, but nft is not usable inside it." >&2
  echo "If this VPS image blocks NET_ADMIN, set privileged: true in docker-compose.gz.yml as a fallback." >&2
  exit 1
fi

if [[ "$DEBUG_MODE" == "true" ]]; then
  echo "gz-agent is running in DEBUG mode. FIREWALL_ENABLED=false, so the dynamic nft gate is not applied."
  echo "The agent still accepts allow refreshes and exposes token-protected debug endpoints."
  echo "Verify no dynamic table is active with:"
  echo "  sudo nft list table inet dynamic_whitelist"
  echo "This command should fail with 'No such file or directory' during debug mode."
else
  echo "gz-agent is running with host network and NET_ADMIN. Verify host rules with:"
  echo "  sudo nft list table inet dynamic_whitelist"
fi

echo "Existing DNAT/MASQUERADE tables are not managed by this container."
