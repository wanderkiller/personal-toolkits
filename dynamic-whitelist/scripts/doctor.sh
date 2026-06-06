#!/usr/bin/env bash
set -uE -o pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ROLE="${1:-}"
shift || true
ALLOW_TEST_IP=""
TAIL_LINES=80

while [[ $# -gt 0 ]]; do
  case "$1" in
    --allow-test)
      ALLOW_TEST_IP="${2:-}"
      shift 2
      ;;
    --tail)
      TAIL_LINES="${2:-80}"
      shift 2
      ;;
    -h|--help)
      ROLE=""
      break
      ;;
    *)
      echo "Unknown argument: $1" >&2
      ROLE=""
      break
      ;;
  esac
done

usage() {
  cat <<'USAGE'
Usage:
  bash scripts/doctor.sh gz [--tail 80]
  bash scripts/doctor.sh hk [--tail 80] [--allow-test 8.8.8.8]

Run on the matching VPS after starting the Docker service. The script prints
clear OK/WARN/FAIL checks and short next-step hints.
USAGE
}

if [[ "$ROLE" != "gz" && "$ROLE" != "hk" ]]; then
  usage
  exit 2
fi

OK_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

ok() { OK_COUNT=$((OK_COUNT + 1)); printf '[OK]   %s\n' "$*"; }
warn() { WARN_COUNT=$((WARN_COUNT + 1)); printf '[WARN] %s\n' "$*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf '[FAIL] %s\n' "$*"; }
info() { printf '[INFO] %s\n' "$*"; }
section() { printf '\n== %s ==\n' "$*"; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

load_env_file() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    fail "Missing $file. Copy the matching env/*.example file and edit tokens/IPs."
    return 1
  fi
  set -a
  # shellcheck disable=SC1090
  . "$file"
  set +a
  ok "Loaded $file"
}

curl_body() {
  local method="$1"
  local url="$2"
  local header_name="${3:-}"
  local header_value="${4:-}"
  local data="${5:-}"
  local tmp status
  tmp="$(mktemp)"
  if [[ -n "$header_name" ]]; then
    if [[ -n "$data" ]]; then
      status="$(curl -sS -m 5 -o "$tmp" -w '%{http_code}' -X "$method" -H "$header_name: $header_value" -H 'content-type: application/json' --data "$data" "$url" 2>"$tmp.err")"
    else
      status="$(curl -sS -m 5 -o "$tmp" -w '%{http_code}' -X "$method" -H "$header_name: $header_value" "$url" 2>"$tmp.err")"
    fi
  else
    status="$(curl -sS -m 5 -o "$tmp" -w '%{http_code}' -X "$method" "$url" 2>"$tmp.err")"
  fi
  printf '%s\n' "$status"
  cat "$tmp"
  if [[ -s "$tmp.err" ]]; then
    printf '\n[CURL_ERROR] '
    cat "$tmp.err"
  fi
  rm -f "$tmp" "$tmp.err"
}

pretty_json() {
  if have_cmd python3; then
    python3 -m json.tool 2>/dev/null || cat
  else
    cat
  fi
}

container_env_value() {
  local container="$1"
  local key="$2"
  docker inspect "$container" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | awk -F= -v k="$key" '$1 == k {print substr($0, length(k) + 2); exit}'
}

check_docker_common() {
  section "Docker"
  if ! have_cmd docker; then
    fail "docker command not found. Install Docker Engine and compose plugin first."
    return 1
  fi
  ok "docker command found: $(command -v docker)"

  if docker compose version >/tmp/dw-compose-version 2>&1; then
    ok "$(cat /tmp/dw-compose-version)"
  else
    fail "docker compose plugin is not usable. Output: $(cat /tmp/dw-compose-version)"
  fi
  rm -f /tmp/dw-compose-version

  if docker info >/tmp/dw-docker-info 2>&1; then
    ok "Docker daemon is reachable"
  else
    fail "Docker daemon is not reachable. Try: sudo systemctl status docker"
    sed 's/^/[INFO] docker info: /' /tmp/dw-docker-info
  fi
  rm -f /tmp/dw-docker-info
}

check_gz() {
  local container="dynamic-whitelist-gz-agent"
  load_env_file env/gz-agent.env || true
  local host="${GZ_AGENT_HOST:-127.0.0.1}"
  local port="${GZ_AGENT_PORT:-9001}"
  local token="${GZ_AGENT_TOKEN:-}"
  local base="http://${host}:${port}"

  check_docker_common

  section "Container"
  if docker ps --format '{{.Names}}' | grep -qx "$container"; then
    ok "$container is running"
  else
    fail "$container is not running. Try: sudo bash scripts/docker-up-gz.sh --debug"
  fi
  docker ps --filter "name=$container" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'

  local fw_enabled debug_enabled
  fw_enabled="$(container_env_value "$container" FIREWALL_ENABLED)"
  debug_enabled="$(container_env_value "$container" DEBUG_ENDPOINTS)"
  info "Container FIREWALL_ENABLED=${fw_enabled:-<unset>} DEBUG_ENDPOINTS=${debug_enabled:-<unset>}"

  section "Host Network"
  if ip route get 1.1.1.1 >/tmp/dw-route 2>&1; then
    ok "Default route detected: $(head -1 /tmp/dw-route)"
  else
    warn "Cannot read default route. PUBLIC_INTERFACE=auto may fail."
  fi
  rm -f /tmp/dw-route
  ip -br addr 2>/dev/null | sed 's/^/[INFO] addr: /' || warn "ip command cannot list addresses"

  section "HTTP Health"
  if [[ -z "$token" ]]; then
    fail "GZ_AGENT_TOKEN is empty in env/gz-agent.env"
  fi
  local result status body
  result="$(curl_body GET "$base/healthz")"
  status="$(printf '%s\n' "$result" | head -1)"
  body="$(printf '%s\n' "$result" | tail -n +2)"
  if [[ "$status" == "200" ]]; then
    ok "GZ healthz reachable at $base/healthz"
    printf '%s\n' "$body" | pretty_json | sed 's/^/[INFO] health: /'
  else
    fail "GZ healthz failed at $base/healthz with HTTP $status"
    printf '%s\n' "$body" | sed 's/^/[INFO] body: /'
    info "Check GZ_AGENT_HOST. It must be an IP present on this VPS, usually the CCN private IP."
  fi

  section "Debug Endpoint"
  result="$(curl_body GET "$base/debug/state" x-agent-token "$token")"
  status="$(printf '%s\n' "$result" | head -1)"
  body="$(printf '%s\n' "$result" | tail -n +2)"
  case "$status" in
    200)
      ok "GZ debug state reachable"
      printf '%s\n' "$body" | pretty_json | sed 's/^/[INFO] state: /'
      ;;
    403)
      fail "GZ debug returned 403. x-agent-token does not match GZ_AGENT_TOKEN."
      ;;
    404)
      warn "GZ debug is disabled. Start with: sudo bash scripts/docker-up-gz.sh --debug"
      ;;
    *)
      fail "GZ debug state failed with HTTP $status"
      printf '%s\n' "$body" | sed 's/^/[INFO] body: /'
      ;;
  esac

  section "nft Gate"
  if docker exec "$container" nft --version >/tmp/dw-nft-version 2>&1; then
    ok "Container nft is usable: $(cat /tmp/dw-nft-version)"
  else
    fail "Container nft is not usable. NET_ADMIN may be blocked by the VPS image."
    sed 's/^/[INFO] nft: /' /tmp/dw-nft-version
  fi
  rm -f /tmp/dw-nft-version

  if nft list table inet dynamic_whitelist >/tmp/dw-nft-table 2>&1; then
    if [[ "$fw_enabled" == "false" ]]; then
      warn "dynamic_whitelist table exists while FIREWALL_ENABLED=false. Restart GZ debug mode to clear old gate."
    else
      ok "dynamic_whitelist table exists in enforce mode"
    fi
    sed 's/^/[INFO] nft: /' /tmp/dw-nft-table | head -80
  else
    if [[ "$fw_enabled" == "false" || "$debug_enabled" == "true" ]]; then
      ok "dynamic_whitelist table is absent in debug mode, so the dynamic gate is not active"
    else
      warn "dynamic_whitelist table is absent. In enforce mode it appears after agent reconcile/start succeeds."
    fi
    sed 's/^/[INFO] nft: /' /tmp/dw-nft-table
  fi
  rm -f /tmp/dw-nft-table

  section "Recent Logs"
  docker logs --tail "$TAIL_LINES" "$container" 2>&1 | sed 's/^/[LOG] /' || warn "Cannot read container logs"
}

check_hk() {
  local container="dynamic-whitelist-hk-relay"
  load_env_file env/hk-relay.env || true
  local port="${HK_RELAY_PORT:-9000}"
  local token="${RELAY_TOKEN:-}"
  local base="http://127.0.0.1:${port}"

  check_docker_common

  section "Container"
  if docker ps --format '{{.Names}}' | grep -qx "$container"; then
    ok "$container is running"
  else
    fail "$container is not running. Try: sudo bash scripts/docker-up-hk.sh --debug"
  fi
  docker ps --filter "name=$container" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
  info "GZ_AGENT_URL=${GZ_AGENT_URL:-<unset>}"
  info "HK_RELAY_DEBUG_ENDPOINTS=$(container_env_value "$container" HK_RELAY_DEBUG_ENDPOINTS)"

  section "Local Relay Health"
  local result status body
  result="$(curl_body GET "$base/healthz")"
  status="$(printf '%s\n' "$result" | head -1)"
  body="$(printf '%s\n' "$result" | tail -n +2)"
  if [[ "$status" == "200" ]]; then
    ok "HK relay healthz reachable at $base/healthz"
    printf '%s\n' "$body" | pretty_json | sed 's/^/[INFO] health: /'
  else
    fail "HK relay healthz failed with HTTP $status"
    printf '%s\n' "$body" | sed 's/^/[INFO] body: /'
  fi

  section "HK -> GZ Debug Path"
  if [[ -z "$token" ]]; then
    fail "RELAY_TOKEN is empty in env/hk-relay.env"
  fi
  result="$(curl_body GET "$base/debug/status" x-relay-token "$token")"
  status="$(printf '%s\n' "$result" | head -1)"
  body="$(printf '%s\n' "$result" | tail -n +2)"
  case "$status" in
    200)
      ok "HK debug status reachable and attempted GZ health check"
      printf '%s\n' "$body" | pretty_json | sed 's/^/[INFO] debug: /'
      ;;
    403)
      fail "HK debug returned 403. x-relay-token does not match RELAY_TOKEN."
      ;;
    404)
      warn "HK debug is disabled. Start with: sudo bash scripts/docker-up-hk.sh --debug"
      ;;
    *)
      fail "HK debug status failed with HTTP $status"
      printf '%s\n' "$body" | sed 's/^/[INFO] body: /'
      ;;
  esac

  result="$(curl_body GET "$base/debug/gz/state" x-relay-token "$token")"
  status="$(printf '%s\n' "$result" | head -1)"
  body="$(printf '%s\n' "$result" | tail -n +2)"
  if [[ "$status" == "200" ]]; then
    ok "HK can proxy to GZ /debug/state over CCN"
    printf '%s\n' "$body" | pretty_json | sed 's/^/[INFO] gz-state: /'
  else
    warn "HK cannot read GZ /debug/state yet. HTTP $status"
    printf '%s\n' "$body" | sed 's/^/[INFO] body: /'
    info "Check GZ_AGENT_URL, GZ_AGENT_TOKEN, CCN route, and Guangzhou GZ_AGENT_HOST bind IP."
  fi

  if [[ -n "$ALLOW_TEST_IP" ]]; then
    section "Allow Write Test"
    result="$(curl_body POST "$base/v1/allow" x-relay-token "$token" "{\"ip\":\"$ALLOW_TEST_IP\",\"device\":\"doctor\",\"mode\":\"wait\"}")"
    status="$(printf '%s\n' "$result" | head -1)"
    body="$(printf '%s\n' "$result" | tail -n +2)"
    if [[ "$status" == "200" ]]; then
      ok "wait-mode allow write accepted for $ALLOW_TEST_IP"
      printf '%s\n' "$body" | pretty_json | sed 's/^/[INFO] allow: /'
    else
      fail "allow write test failed with HTTP $status"
      printf '%s\n' "$body" | sed 's/^/[INFO] body: /'
    fi
  else
    info "Skipped write test. Run: bash scripts/doctor.sh hk --allow-test 8.8.8.8"
  fi

  section "Recent Logs"
  docker logs --tail "$TAIL_LINES" "$container" 2>&1 | sed 's/^/[LOG] /' || warn "Cannot read container logs"
}

if [[ "$ROLE" == "gz" ]]; then
  check_gz
else
  check_hk
fi

section "Summary"
printf '[INFO] OK=%s WARN=%s FAIL=%s\n' "$OK_COUNT" "$WARN_COUNT" "$FAIL_COUNT"
if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
exit 0