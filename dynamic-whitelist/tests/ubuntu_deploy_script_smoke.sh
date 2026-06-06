#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${TMPDIR:-/tmp}/dynamic-whitelist-script-smoke-$$"
FAKE_BIN="$WORK_DIR/fakebin"
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR" "$FAKE_BIN"
cp -a "$SOURCE_DIR/." "$WORK_DIR/project"
cd "$WORK_DIR/project"
cp env/gz-agent.env.example env/gz-agent.env
cp env/hk-relay.env.example env/hk-relay.env

cat > "$FAKE_BIN/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "compose" && "${2:-}" == "version" ]]; then
  echo "Docker Compose version v2.fake"
  exit 0
fi

if [[ "${1:-}" == "compose" && " $* " == *" config "* ]]; then
  if [[ " $* " == *"docker-compose.hk.yml"* ]]; then
    cat <<'CONFIG'
services:
  hk-relay:
    ports:
      - mode: ingress
        host_ip: 127.0.0.1
        target: 9000
        published: "9000"
        protocol: tcp
CONFIG
  else
    cat <<'CONFIG'
services:
  gz-agent:
    network_mode: host
    cap_add:
      - NET_ADMIN
      - NET_RAW
CONFIG
  fi
  exit 0
fi

if [[ "${1:-}" == "compose" && " $* " == *" up "* ]]; then
  echo "compose up ok"
  exit 0
fi

if [[ "${1:-}" == "info" ]]; then
  if [[ "$*" == *"--format"* ]]; then
    echo "linux"
  else
    echo "fake docker info"
  fi
  exit 0
fi

if [[ "${1:-}" == "ps" ]]; then
  if [[ " $* " == *" --format {{.Names}} "* ]]; then
    printf 'dynamic-whitelist-gz-agent\ndynamic-whitelist-hk-relay\n'
  else
    echo "NAMES IMAGE STATUS PORTS"
    echo "dynamic-whitelist-gz-agent fake running"
    echo "dynamic-whitelist-hk-relay fake running"
  fi
  exit 0
fi

if [[ "${1:-}" == "inspect" ]]; then
  container="${2:-}"
  if [[ "$container" == "dynamic-whitelist-gz-agent" ]]; then
    printf 'FIREWALL_ENABLED=false\nDEBUG_ENDPOINTS=true\n'
  elif [[ "$container" == "dynamic-whitelist-hk-relay" ]]; then
    printf 'HK_RELAY_DEBUG_ENDPOINTS=true\n'
  fi
  exit 0
fi

if [[ "${1:-}" == "exec" ]]; then
  echo "nftables v1.fake"
  exit 0
fi

if [[ "${1:-}" == "logs" ]]; then
  echo "fake container log"
  exit 0
fi

echo "unexpected docker invocation: $*" >&2
exit 1
FAKE_DOCKER
chmod +x "$FAKE_BIN/docker"

cat > "$FAKE_BIN/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -euo pipefail
out=""
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      out="$2"
      shift 2
      ;;
    http://*)
      url="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done
body='{"ok":true}'
case "$url" in
  */healthz) body='{"ok":true,"role":"fake"}' ;;
  */debug/state|*/debug/gz/state) body='{"ok":true,"firewall":{"enabled":false,"mode":"debug_disabled"},"active":[]}' ;;
  */debug/status) body='{"ok":true,"gz_health":{"status":200,"body":{"ok":true}}}' ;;
  */v1/allow) body='{"ok":true,"gz":{"status":200,"body":{"ok":true}}}' ;;
esac
if [[ -n "$out" ]]; then
  printf '%s' "$body" > "$out"
fi
printf '200'
FAKE_CURL
chmod +x "$FAKE_BIN/curl"

cat > "$FAKE_BIN/ip" <<'FAKE_IP'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "route" ]]; then
  echo "1.1.1.1 via 10.0.0.1 dev eth0 src 10.0.0.2"
elif [[ " $* " == *" -o "* ]]; then
  echo "2: eth0    inet 10.0.0.2/24 brd 10.0.0.255 scope global eth0"
elif [[ "${1:-}" == "link" && "${2:-}" == "show" ]]; then
  exit 0
else
  echo "eth0             UP             10.0.0.2/24"
fi
FAKE_IP
chmod +x "$FAKE_BIN/ip"

cat > "$FAKE_BIN/nft" <<'FAKE_NFT'
#!/usr/bin/env bash
set -euo pipefail
echo "Error: No such file or directory" >&2
exit 1
FAKE_NFT
chmod +x "$FAKE_BIN/nft"
cat > "$FAKE_BIN/systemctl" <<'FAKE_SYSTEMCTL'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "is-active" ]]; then
  exit 0
fi
exit 0
FAKE_SYSTEMCTL
chmod +x "$FAKE_BIN/systemctl"

PATH="$FAKE_BIN:$PATH" bash scripts/docker-up-gz.sh >/tmp/gz-normal.out
PATH="$FAKE_BIN:$PATH" bash scripts/docker-up-gz.sh --debug >/tmp/gz-debug.out
PATH="$FAKE_BIN:$PATH" bash scripts/docker-up-hk.sh >/tmp/hk-normal.out
PATH="$FAKE_BIN:$PATH" bash scripts/docker-up-hk.sh --debug >/tmp/hk-debug.out
PATH="$FAKE_BIN:$PATH" bash scripts/doctor.sh gz >/tmp/doctor-gz.out
PATH="$FAKE_BIN:$PATH" bash scripts/doctor.sh hk --allow-test 8.8.8.8 >/tmp/doctor-hk.out
rm -f env/gz-agent.env env/hk-relay.env
printf '1\n1\n1\n10.0.0.2\nagent-token\nauto\n' | PATH="$FAKE_BIN:$PATH" bash scripts/deploy.sh >/tmp/deploy-gz-menu.out 2>&1
printf '1\n2\n1\n10.0.0.2\n\nagent-token\nrelay-token\n' | PATH="$FAKE_BIN:$PATH" bash scripts/deploy.sh >/tmp/deploy-hk-menu.out 2>&1

grep -q "gz-agent is running with host network" /tmp/gz-normal.out
grep -q "gz-agent is running in DEBUG mode" /tmp/gz-debug.out
grep -q "hk-relay is running. Debug proxy endpoints are disabled" /tmp/hk-normal.out
grep -q "hk-relay is running in DEBUG mode" /tmp/hk-debug.out
grep -q "\[OK\].*GZ healthz reachable" /tmp/doctor-gz.out
grep -q "\[OK\].*HK relay healthz reachable" /tmp/doctor-hk.out
grep -q "\[OK\].*wait-mode allow write accepted" /tmp/doctor-hk.out
grep -q "Deployment finished. Role=gz Mode=debug" /tmp/deploy-gz-menu.out
grep -q "Deployment finished. Role=hk Mode=debug" /tmp/deploy-hk-menu.out

echo "ubuntu deploy script smoke ok"