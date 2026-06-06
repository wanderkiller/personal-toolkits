#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ "$#" -gt 0 ]]; then
  echo "This deployment entrypoint is interactive. Run without arguments:" >&2
  echo "  sudo bash scripts/deploy.sh" >&2
  exit 2
fi

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run with sudo:" >&2
  echo "  sudo bash scripts/deploy.sh" >&2
  exit 1
fi

PREFLIGHT_FAILS=0
PREFLIGHT_WARNS=0
PREFLIGHT_ROLE=""
PREFLIGHT_RUN_MODE=""

ok() { printf '[OK]   %s\n' "$*"; }
warn() { PREFLIGHT_WARNS=$((PREFLIGHT_WARNS + 1)); printf '[WARN] %s\n' "$*"; }
fail() { PREFLIGHT_FAILS=$((PREFLIGHT_FAILS + 1)); printf '[FAIL] %s\n' "$*"; }
info() { printf '[INFO] %s\n' "$*"; }
section() { printf '\n== %s ==\n' "$*"; }

ask() {
  local prompt="$1"
  local default="${2:-}"
  local value
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " value
    printf '%s' "${value:-$default}"
  else
    while true; do
      read -r -p "$prompt: " value
      if [[ -n "$value" ]]; then
        printf '%s' "$value"
        return
      fi
      echo "This value is required." >&2
    done
  fi
}

confirm() {
  local prompt="$1"
  local default="${2:-Y}"
  local value suffix
  if [[ "$default" == "Y" ]]; then
    suffix="Y/n"
  else
    suffix="y/N"
  fi
  read -r -p "$prompt [$suffix]: " value
  value="${value:-$default}"
  [[ "$value" == "Y" || "$value" == "y" || "$value" == "yes" || "$value" == "YES" ]]
}

choose() {
  local prompt="$1"
  shift
  local options=("$@")
  local value
  while true; do
    echo >&2
    echo "$prompt" >&2
    local i=1
    for option in "${options[@]}"; do
      echo "  $i) $option" >&2
      i=$((i + 1))
    done
    read -r -p "Select: " value
    if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= ${#options[@]} )); then
      printf '%s' "$value"
      return
    fi
    echo "Invalid selection." >&2
  done
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

first_private_ipv4() {
  ip -o -4 addr show scope global 2>/dev/null \
    | awk '{print $4}' \
    | cut -d/ -f1 \
    | awk '$1 ~ /^10\./ || $1 ~ /^192\.168\./ || $1 ~ /^172\.(1[6-9]|2[0-9]|3[0-1])\./ {print; exit}'
}

show_ipv4s() {
  echo "Available IPv4 addresses:"
  ip -br -4 addr 2>/dev/null || true
  echo
}

is_port_listening() {
  local port="$1"
  if have_cmd ss; then
    ss -lntup 2>/dev/null | awk -v p=":$port" '$5 ~ p {found=1} END {exit found ? 0 : 1}'
  else
    return 1
  fi
}

env_value() {
  local file="$1"
  local key="$2"
  awk -F= -v k="$key" '
    $1 == k {
      sub(/^[^=]*=/, "")
      gsub(/^"|"$/, "")
      print
      exit
    }
  ' "$file" 2>/dev/null
}

is_local_ipv4() {
  local wanted="$1"
  ip -o -4 addr show scope global 2>/dev/null \
    | awk '{print $4}' \
    | cut -d/ -f1 \
    | grep -Fxq "$wanted"
}

health_base_from_allow_url() {
  local url="$1"
  if [[ "$url" == */v1/allow ]]; then
    printf '%s' "${url%/v1/allow}"
  else
    printf '%s' "${url%/}"
  fi
}

validate_compose_config() {
  local role="$1"
  local run_mode="$2"
  local tmp="/tmp/dw-compose-${role}-$$.yml"
  local files=()

  if [[ "$role" == "gz" ]]; then
    files=(-f docker-compose.gz.yml)
    [[ "$run_mode" == "debug" ]] && files+=(-f docker-compose.gz.debug.yml)
  else
    files=(-f docker-compose.hk.yml)
    [[ "$run_mode" == "debug" ]] && files+=(-f docker-compose.hk.debug.yml)
  fi

  if ! docker compose "${files[@]}" config >"$tmp" 2>"$tmp.err"; then
    fail "docker compose config failed for $role. Output: $(cat "$tmp.err")"
    rm -f "$tmp" "$tmp.err"
    return
  fi
  ok "docker compose config is valid for $role/$run_mode"

  if [[ "$role" == "gz" ]]; then
    grep -q '^    network_mode: host$' "$tmp" && ok "gz compose uses host network" || fail "gz compose must use network_mode: host"
    grep -q '^      - NET_ADMIN$' "$tmp" && ok "gz compose includes NET_ADMIN" || fail "gz compose must include NET_ADMIN"
    grep -q '^      - NET_RAW$' "$tmp" && ok "gz compose includes NET_RAW" || warn "gz compose does not include NET_RAW; nft may still work, but diagnostics are weaker"
  else
    if grep -q '127\.0\.0\.1:9000:9000' "$tmp" || { grep -q 'host_ip: 127\.0\.0\.1' "$tmp" && grep -Eq 'published: "?9000"?' "$tmp"; }; then
      ok "hk compose publishes relay only on 127.0.0.1:9000"
    else
      warn "hk compose port binding is not the expected 127.0.0.1:9000:9000"
    fi
  fi
  rm -f "$tmp" "$tmp.err"
}

preflight_reset() {
  PREFLIGHT_FAILS=0
  PREFLIGHT_WARNS=0
}

preflight_common() {
  section "Runtime Environment"
  preflight_reset

  if [[ "$(uname -s 2>/dev/null || true)" == "Linux" ]]; then
    ok "Kernel: $(uname -srmo)"
  else
    fail "This deploy script must run on Linux VPS, not $(uname -s 2>/dev/null || echo unknown)."
  fi

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    info "OS: ${PRETTY_NAME:-unknown}"
    if [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "22.04" ]]; then
      ok "Ubuntu 22.04 detected"
    else
      warn "Tested baseline is Ubuntu 22.04. Current OS is ${PRETTY_NAME:-unknown}."
    fi
  else
    warn "/etc/os-release is not readable; cannot verify Ubuntu 22.04 baseline."
  fi

  case "$(uname -m)" in
    x86_64|amd64|aarch64|arm64) ok "CPU architecture supported by python:3.12-slim: $(uname -m)" ;;
    *) warn "Unusual CPU architecture: $(uname -m). Docker base image may not support it." ;;
  esac

  for cmd in docker ip awk sed grep curl ss df; do
    if have_cmd "$cmd"; then
      ok "Command found: $cmd"
    else
      if [[ "$cmd" == "docker" ]]; then
        fail "docker command not found. Install Docker Engine first."
      else
        warn "Command missing: $cmd. Doctor output may be less useful."
      fi
    fi
  done

  if have_cmd nft; then
    ok "Host nft command found: $(nft --version 2>/dev/null || true)"
  else
    warn "Host nft command not found. Container still includes nft, but host verification commands will be limited."
  fi

  if have_cmd docker; then
    if docker compose version >/tmp/dw-compose-version 2>&1; then
      ok "$(cat /tmp/dw-compose-version)"
    else
      fail "docker compose plugin is not usable. Install docker compose plugin. Output: $(cat /tmp/dw-compose-version)"
    fi
    rm -f /tmp/dw-compose-version

    if docker info >/tmp/dw-docker-info 2>&1; then
      ok "Docker daemon is reachable"
      local ostype
      ostype="$(docker info --format '{{.OSType}}' 2>/dev/null || true)"
      if [[ "$ostype" == "linux" ]]; then
        ok "Docker OSType is linux"
      elif [[ -n "$ostype" ]]; then
        warn "Docker OSType is $ostype; expected linux."
      fi
    else
      fail "Docker daemon is not reachable. Try: sudo systemctl status docker"
      sed 's/^/[INFO] docker info: /' /tmp/dw-docker-info
    fi
    rm -f /tmp/dw-docker-info
  fi

  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet docker 2>/dev/null; then
      ok "systemd docker service is active"
    else
      warn "systemd docker service is not active or not readable. Docker may still be socket-activated."
    fi
  fi

  local disk_avail
  disk_avail="$(df -Pm . 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)"
  if [[ "$disk_avail" =~ ^[0-9]+$ && "$disk_avail" -ge 1024 ]]; then
    ok "Free disk space here: ${disk_avail} MB"
  else
    warn "Free disk space may be low: ${disk_avail} MB. Docker build/pull may fail."
  fi

  local mem_total
  mem_total="$(awk '/MemTotal/ {printf "%d", $2 / 1024}' /proc/meminfo 2>/dev/null || echo 0)"
  if [[ "$mem_total" =~ ^[0-9]+$ && "$mem_total" -ge 512 ]]; then
    ok "Memory total: ${mem_total} MB"
  else
    warn "Memory may be low: ${mem_total} MB. Docker build can fail on very small VPS images."
  fi

  if [[ "$PREFLIGHT_FAILS" -gt 0 ]]; then
    echo
    fail "Environment has $PREFLIGHT_FAILS fatal issue(s). Fix them before deployment."
    return 1
  fi
  if [[ "$PREFLIGHT_WARNS" -gt 0 ]]; then
    echo
    warn "Environment has $PREFLIGHT_WARNS warning(s)."
  fi
  return 0
}

preflight_role() {
  local role="$1"
  local run_mode="$2"
  section "Role-specific Checks"
  PREFLIGHT_ROLE="$role"
  PREFLIGHT_RUN_MODE="$run_mode"
  PREFLIGHT_WARNS=0
  PREFLIGHT_FAILS=0

  if [[ "$role" == "gz" ]]; then
    ok "Selected role: Mainland / Guangzhou agent"
    if [[ "$run_mode" == "debug" ]]; then
      ok "Selected run mode: debug, dynamic nft gate disabled"
    else
      warn "Selected run mode: enforce. Dynamic nft forward gate will be enabled after startup."
    fi
    if is_port_listening 9001; then
      warn "TCP port 9001 is already listening. If an old gz-agent container is running this is OK; otherwise check conflict."
      ss -lntup 2>/dev/null | awk '$5 ~ /:9001/ {print "[INFO] port: "$0}' || true
    else
      ok "TCP port 9001 is free before deployment"
    fi
    if [[ -d /var/lib/dynamic-whitelist ]]; then
      ok "State directory exists: /var/lib/dynamic-whitelist"
    else
      ok "State directory will be created: /var/lib/dynamic-whitelist"
    fi
    if [[ -r /proc/net/route ]]; then
      ok "/proc/net/route readable for PUBLIC_INTERFACE=auto"
    else
      warn "/proc/net/route not readable. PUBLIC_INTERFACE=auto may fail."
    fi
  else
    ok "Selected role: Hong Kong relay"
    if is_port_listening 9000; then
      warn "TCP port 9000 is already listening. If an old hk-relay container is running this is OK; otherwise check conflict."
      ss -lntup 2>/dev/null | awk '$5 ~ /:9000/ {print "[INFO] port: "$0}' || true
    else
      ok "TCP port 9000 is free before deployment"
    fi
    ok "Relay container binds host 127.0.0.1:9000; public HTTPS should be provided by Nginx or another reverse proxy."
  fi

  if [[ "$PREFLIGHT_WARNS" -gt 0 ]]; then
    echo
    warn "Role checks produced $PREFLIGHT_WARNS warning(s)."
    if ! confirm "Continue anyway" "Y"; then
      echo "Stopped by user."
      exit 1
    fi
  fi
}

write_gz_env() {
  local host agent_token public_if
  echo
  echo "Mainland mode: Guangzhou agent configuration"
  show_ipv4s
  host="$(ask 'GZ CCN/private bind IP' "$(first_private_ipv4)")"
  agent_token="$(ask 'GZ_AGENT_TOKEN')"
  public_if="$(ask 'PUBLIC_INTERFACE' 'auto')"

  cat > env/gz-agent.env <<EOF
GZ_AGENT_HOST=$host
GZ_AGENT_PORT=9001
GZ_AGENT_TOKEN=$agent_token
PUBLIC_INTERFACE=$public_if
PROTECT_TCP=true
PROTECT_UDP=true
FIREWALL_ENABLED=true
DEBUG_ENDPOINTS=false
ALLOWLIST_MAX_IPS=6
ALLOWLIST_TTL_SECONDS=86400
ALLOWLIST_STATE=/data/state.json
NFT_BIN=nft
NFT_FAMILY=inet
NFT_TABLE=dynamic_whitelist
NFT_ALLOW_SET=allow4
NFT_CHAIN=forward_guard
NFT_PRIORITY=-150
RECONCILE_INTERVAL_SECONDS=300
EOF
}

write_hk_env() {
  local gz_ip gz_url agent_token relay_token
  echo
  echo "Hong Kong mode: relay configuration"
  gz_ip="$(ask 'Guangzhou CCN/private IP')"
  gz_url="$(ask 'GZ_AGENT_URL' "http://$gz_ip:9001/v1/allow")"
  agent_token="$(ask 'GZ_AGENT_TOKEN, must match Guangzhou')"
  relay_token="$(ask 'RELAY_TOKEN')"

  cat > env/hk-relay.env <<EOF
HK_RELAY_HOST=0.0.0.0
HK_RELAY_PORT=9000
RELAY_TOKEN=$relay_token
GZ_AGENT_URL=$gz_url
GZ_AGENT_TOKEN=$agent_token
GZ_AGENT_TIMEOUT=2.0
HK_RELAY_QUEUE_MAX=256
HK_RELAY_DEBUG_ENDPOINTS=false
HK_RELAY_FORWARD_RETRIES=3
HK_RELAY_FORWARD_RETRY_DELAY=0.5
EOF
}

ensure_env() {
  local role="$1"
  local file writer
  if [[ "$role" == "gz" ]]; then
    file="env/gz-agent.env"
    writer="write_gz_env"
  else
    file="env/hk-relay.env"
    writer="write_hk_env"
  fi

  if [[ -f "$file" ]]; then
    if confirm "$file exists. Reuse it" "Y"; then
      echo "Reusing $file"
      return
    fi
  fi
  $writer
}

preflight_env_and_compose() {
  local role="$1"
  local run_mode="$2"
  local file
  section "Configuration Preflight"
  PREFLIGHT_FAILS=0
  PREFLIGHT_WARNS=0

  if [[ "$role" == "gz" ]]; then
    file="env/gz-agent.env"
    local host token public_if ip_forward
    host="$(env_value "$file" GZ_AGENT_HOST)"
    token="$(env_value "$file" GZ_AGENT_TOKEN)"
    public_if="$(env_value "$file" PUBLIC_INTERFACE)"

    [[ -n "$token" ]] && ok "GZ_AGENT_TOKEN is set" || fail "GZ_AGENT_TOKEN is empty"
    if [[ "$host" == "0.0.0.0" ]]; then
      warn "GZ_AGENT_HOST is 0.0.0.0. Prefer the CCN/private IP so HK reaches only the intended interface."
    elif is_local_ipv4 "$host"; then
      ok "GZ_AGENT_HOST is assigned locally: $host"
    else
      fail "GZ_AGENT_HOST is not a local IPv4 on this VPS: $host"
      show_ipv4s
    fi

    if [[ "${public_if:-auto}" == "auto" ]]; then
      ok "PUBLIC_INTERFACE=auto will use the default route interface"
    elif ip link show "$public_if" >/dev/null 2>&1; then
      ok "PUBLIC_INTERFACE exists: $public_if"
    else
      fail "PUBLIC_INTERFACE does not exist: $public_if"
    fi

    ip_forward="$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo unknown)"
    if [[ "$ip_forward" == "1" ]]; then
      ok "IPv4 forwarding is enabled"
    else
      fail "IPv4 forwarding is $ip_forward. Existing Guangzhou DNAT/MASQUERADE forwarding needs net.ipv4.ip_forward=1."
      info "Fix example: sudo sysctl -w net.ipv4.ip_forward=1"
    fi
  else
    file="env/hk-relay.env"
    local gz_url gz_base relay_token agent_token http_code
    gz_url="$(env_value "$file" GZ_AGENT_URL)"
    relay_token="$(env_value "$file" RELAY_TOKEN)"
    agent_token="$(env_value "$file" GZ_AGENT_TOKEN)"

    [[ -n "$relay_token" ]] && ok "RELAY_TOKEN is set" || fail "RELAY_TOKEN is empty"
    [[ -n "$agent_token" ]] && ok "GZ_AGENT_TOKEN is set" || fail "GZ_AGENT_TOKEN is empty"
    [[ -n "$gz_url" ]] && ok "GZ_AGENT_URL is set: $gz_url" || fail "GZ_AGENT_URL is empty"

    if [[ "$gz_url" =~ localhost|127\.0\.0\.1 ]]; then
      fail "GZ_AGENT_URL points to localhost. HK relay must use Guangzhou CCN/private IP."
    fi

    if [[ -n "$gz_url" ]] && have_cmd curl; then
      gz_base="$(health_base_from_allow_url "$gz_url")"
      http_code="$(curl -sS -m 2 -o /tmp/dw-gz-health -w '%{http_code}' "$gz_base/healthz" 2>/tmp/dw-gz-health.err || true)"
      if [[ "$http_code" == "200" ]]; then
        ok "Guangzhou health endpoint reachable from HK: $gz_base/healthz"
      else
        warn "Cannot reach Guangzhou health endpoint yet: $gz_base/healthz status=${http_code:-curl_error}"
        sed 's/^/[INFO] curl: /' /tmp/dw-gz-health.err 2>/dev/null || true
      fi
      rm -f /tmp/dw-gz-health /tmp/dw-gz-health.err
    fi
  fi

  validate_compose_config "$role" "$run_mode"

  if [[ "$PREFLIGHT_FAILS" -gt 0 ]]; then
    echo
    fail "Configuration has $PREFLIGHT_FAILS fatal issue(s). Fix them before deployment."
    exit 1
  fi
  if [[ "$PREFLIGHT_WARNS" -gt 0 ]]; then
    echo
    warn "Configuration checks produced $PREFLIGHT_WARNS warning(s)."
    if ! confirm "Continue anyway" "Y"; then
      echo "Stopped by user."
      exit 1
    fi
  fi
}

run_deploy() {
  local role="$1"
  local run_mode="$2"
  local up_arg=()
  if [[ "$run_mode" == "debug" ]]; then
    up_arg=(--debug)
  fi

  preflight_role "$role" "$run_mode"
  ensure_env "$role"
  preflight_env_and_compose "$role" "$run_mode"

  if [[ "$role" == "gz" ]]; then
    bash scripts/docker-up-gz.sh "${up_arg[@]}"
    bash scripts/doctor.sh gz || true
  else
    bash scripts/docker-up-hk.sh "${up_arg[@]}"
    bash scripts/doctor.sh hk || true
    echo
    echo "Optional HK -> Guangzhou write-through test:"
    echo "  sudo bash scripts/doctor.sh hk --allow-test 8.8.8.8"
  fi

  echo
  echo "Deployment finished. Role=$role Mode=$run_mode"
  if [[ "$run_mode" == "debug" ]]; then
    echo "Debug mode does not enable the dynamic nft gate. Run this menu again and choose Enforce after the chain is verified."
  fi
}

run_doctor_menu() {
  local doctor_role allow_ip
  doctor_role="$(choose 'Diagnostics target' 'Mainland / Guangzhou agent' 'Hong Kong relay')"
  if [[ "$doctor_role" == "1" ]]; then
    bash scripts/doctor.sh gz || true
  else
    if confirm "Run HK -> Guangzhou write test" "N"; then
      allow_ip="$(ask 'Public IPv4 to test' '8.8.8.8')"
      bash scripts/doctor.sh hk --allow-test "$allow_ip" || true
    else
      bash scripts/doctor.sh hk || true
    fi
  fi
}

main() {
  local action role_choice mode_choice role run_mode
  echo "Dynamic Whitelist Docker Deployment"
  echo "One package, one menu. First deployment should use Debug mode."

  if ! preflight_common; then
    exit 1
  fi

  action="$(choose 'What do you want to do?' 'Deploy / update service' 'Run diagnostics only' 'Exit')"
  case "$action" in
    1)
      role_choice="$(choose 'Choose deployment mode' 'Mainland mode / Guangzhou agent' 'Hong Kong mode / HK relay')"
      if [[ "$role_choice" == "1" ]]; then
        role="gz"
      else
        role="hk"
      fi
      mode_choice="$(choose 'Choose run mode' 'Debug mode, no firewall gate, recommended first' 'Enforce mode, enable real firewall gate')"
      if [[ "$mode_choice" == "1" ]]; then
        run_mode="debug"
      else
        run_mode="enforce"
      fi
      run_deploy "$role" "$run_mode"
      ;;
    2)
      run_doctor_menu
      ;;
    3)
      echo "Bye."
      ;;
  esac
}

main