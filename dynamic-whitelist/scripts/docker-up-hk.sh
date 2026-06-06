#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DEBUG_MODE=false
if [[ "${1:-}" == "--debug" ]]; then
  DEBUG_MODE=true
elif [[ "${1:-}" != "" ]]; then
  echo "Usage: sudo bash scripts/docker-up-hk.sh [--debug]" >&2
  exit 1
fi

COMPOSE_FILES=(-f docker-compose.hk.yml)
if [[ "$DEBUG_MODE" == "true" ]]; then
  COMPOSE_FILES+=(-f docker-compose.hk.debug.yml)
fi

if [[ ! -f env/hk-relay.env ]]; then
  cp env/hk-relay.env.example env/hk-relay.env
  echo "Created env/hk-relay.env. Edit tokens and GZ_AGENT_URL, then rerun this script." >&2
  exit 1
fi

docker compose "${COMPOSE_FILES[@]}" up -d --build
docker ps --filter name=dynamic-whitelist-hk-relay

if [[ "$DEBUG_MODE" == "true" ]]; then
  echo "hk-relay is running in DEBUG mode. Token-protected debug proxy endpoints are enabled."
else
  echo "hk-relay is running. Debug proxy endpoints are disabled."
fi
