#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${ROOT_DIR}/dist"
VERSION="${1:-dynamic-whitelist}"
ARCHIVE="${OUT_DIR}/${VERSION}.tar.gz"

mkdir -p "$OUT_DIR"
tar \
  --exclude='./dist' \
  --exclude='./env/*.env' \
  --exclude='./.git' \
  -C "$ROOT_DIR" \
  -czf "$ARCHIVE" \
  .

echo "$ARCHIVE"

