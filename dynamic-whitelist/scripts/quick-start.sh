#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ "$#" -gt 0 ]]; then
  echo "quick-start is now interactive. Run without arguments:" >&2
  echo "  sudo bash scripts/quick-start.sh" >&2
  exit 2
fi

exec bash scripts/deploy.sh