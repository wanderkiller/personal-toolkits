
## One-menu Docker Deployment
### Runtime Environment Detection

The interactive menu runs a preflight check before deployment. It prints `[OK]`, `[WARN]`, and `[FAIL]` for:

```text
Linux kernel and CPU architecture
Ubuntu 22.04 baseline check
Docker command and Docker daemon reachability
Docker Compose plugin
Docker OSType
basic tools: ip, awk, sed, grep, curl, nft
free disk space for image build/pull
role-specific port checks: 9001 for Guangzhou, 9000 for HK
PUBLIC_INTERFACE=auto prerequisites on Guangzhou
```

Fatal `[FAIL]` items stop deployment. `[WARN]` items are shown with a continue prompt so you can decide during VPS integration.

Both VPS roles are shipped in the same tarball. After upload and extract, run only this interactive menu:

```bash
sudo bash scripts/deploy.sh
```

Choose from the menu:

```text
1) Deploy / update service
2) Run diagnostics only
3) Exit
```

Then choose:

```text
1) Mainland mode / Guangzhou agent
2) Hong Kong mode / HK relay
```

First deployment should choose Debug mode. Debug mode validates the chain without enabling the dynamic nft firewall gate. After FC -> HK -> CCN -> Guangzhou is confirmed, run the same menu again and choose Enforce mode.
# Docker Deployment
## Simplified VPS Start

After uploading and extracting the tarball, use the interactive starter instead of editing env files by hand:

```bash
# Guangzhou VPS, first run
sudo bash scripts/deploy.sh

# HK VPS, first run
sudo bash scripts/deploy.sh
```

The script asks only for the required IP/token values, writes the env file, starts Docker in debug mode, and runs `doctor.sh` automatically. After the full chain works, switch the same role to enforce mode:

```bash
sudo bash scripts/deploy.sh
sudo bash scripts/deploy.sh
```

This is the preferred deployment path for the two VPS machines.

## Guangzhou VPS

The Guangzhou container must share the host network namespace and hold
`NET_ADMIN`, otherwise nftables changes would only affect the container itself.
The `scripts/docker-up-gz.sh` script enforces this before startup and verifies
`nft list ruleset` from inside the running container after startup.

Prepare config:

```bash
cd dynamic-whitelist
cp env/gz-agent.env.example env/gz-agent.env
vim env/gz-agent.env
```

Recommended `env/gz-agent.env`:

```text
GZ_AGENT_HOST=10.0.0.2
GZ_AGENT_PORT=9001
GZ_AGENT_TOKEN=replace-with-agent-token
PUBLIC_INTERFACE=auto
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
```

This agent owns only `table inet dynamic_whitelist`. It does not modify your existing
DNAT or MASQUERADE rules. SSH `18650/tcp` must remain open in your existing INPUT
chain.

Start:

```bash
sudo bash scripts/docker-up-gz.sh
sudo docker logs -f dynamic-whitelist-gz-agent
```

The script creates `env/gz-agent.env` on first run and exits so you can edit it.
Run it again after editing.

Check:

```bash
sudo docker ps
curl -s http://10.0.0.2:9001/healthz
sudo nft list table inet dynamic_whitelist
sudo nft list table inet dynamic_whitelist
```

Expected firewall model:

```text
Existing INPUT chain keeps 18650/tcp open for SSH
Existing nat PREROUTING keeps DNAT forwarding to HK over CCN
Existing nat POSTROUTING keeps MASQUERADE
table inet dynamic_whitelist / forward_guard gates forwarded public-interface traffic
allowlisted source IP -> forwarded normally
non-allowlisted forwarded TCP -> reject with tcp reset
non-allowlisted forwarded UDP -> drop
```

If nftables fails from inside Docker on a specific VPS image, temporarily change
`cap_add` to `privileged: true` in `docker-compose.gz.yml`. Use that only as a
fallback.

## HK Relay VPS

Prepare config:

```bash
cd dynamic-whitelist
cp env/hk-relay.env.example env/hk-relay.env
vim env/hk-relay.env
```

Recommended `env/hk-relay.env`:

```text
HK_RELAY_HOST=0.0.0.0
HK_RELAY_PORT=9000
RELAY_TOKEN=replace-with-relay-token
GZ_AGENT_URL=http://10.0.0.2:9001/v1/allow
GZ_AGENT_TOKEN=replace-with-agent-token
GZ_AGENT_TIMEOUT=2.0
HK_RELAY_QUEUE_MAX=256
HK_RELAY_DEBUG_ENDPOINTS=false
HK_RELAY_FORWARD_RETRIES=3
HK_RELAY_FORWARD_RETRY_DELAY=0.5
```

Start:

```bash
sudo bash scripts/docker-up-hk.sh
sudo docker logs -f dynamic-whitelist-hk-relay
```

The script creates `env/hk-relay.env` on first run and exits so you can edit it.
Run it again after editing.

Check:

```bash
curl -s http://127.0.0.1:9000/healthz
```

Keep Nginx on the HK host as the public HTTPS front. The compose file maps the
container to `127.0.0.1:9000` on the host, so the Python relay is not directly exposed.
The compose file overrides `HK_RELAY_HOST=0.0.0.0` inside the container so Docker port
publishing can reach it.


## Debug VPS Integration
### One-command diagnostics

After starting in debug mode, run the matching doctor command on each VPS:

```bash
# Guangzhou VPS
sudo bash scripts/doctor.sh gz

# HK Relay VPS
sudo bash scripts/doctor.sh hk

# Optional write-through test from HK to Guangzhou
sudo bash scripts/doctor.sh hk --allow-test 8.8.8.8
```

The doctor output uses `[OK]`, `[WARN]`, and `[FAIL]` lines and prints the exact next area to inspect: Docker daemon, container state, health endpoint, token mismatch, CCN reachability, nft gate state, or recent container logs.

Use debug mode for the first VPS integration pass. It validates FC -> HK -> CCN -> Guangzhou delivery while keeping the dynamic firewall gate disabled.

Start Guangzhou in debug mode:

```bash
sudo bash scripts/docker-up-gz.sh --debug
sudo docker logs -f dynamic-whitelist-gz-agent
```

Start HK relay in debug mode:

```bash
sudo bash scripts/docker-up-hk.sh --debug
sudo docker logs -f dynamic-whitelist-hk-relay
```

Debug mode changes only these switches through compose overrides:

```text
FIREWALL_ENABLED=false
DEBUG_ENDPOINTS=true
HK_RELAY_DEBUG_ENDPOINTS=true
```

Guarantees in debug mode:

```text
/v1/allow still validates and records client IP state
TTL, max 6 IPs, and LRU eviction still run
nft ruleset can be previewed through /debug/ruleset
nft -f - is not executed, so the dynamic forward gate is not applied
only table inet dynamic_whitelist may be deleted to clear an old dynamic gate
existing DNAT/MASQUERADE/INPUT rules are not managed or rewritten
```

Direct Guangzhou checks from the CCN side:

```bash
curl -s http://10.0.0.2:9001/healthz
curl -s -H "x-agent-token: <GZ_AGENT_TOKEN>" http://10.0.0.2:9001/debug/state
curl -s -H "x-agent-token: <GZ_AGENT_TOKEN>" http://10.0.0.2:9001/debug/ruleset
sudo nft list table inet dynamic_whitelist
```

During debug mode, `sudo nft list table inet dynamic_whitelist` should fail with a missing-table error. That means the dynamic gate is not active.

HK-side proxy checks:

```bash
curl -s -H "x-relay-token: <RELAY_TOKEN>" http://127.0.0.1:9000/debug/status
curl -s -H "x-relay-token: <RELAY_TOKEN>" http://127.0.0.1:9000/debug/gz/state
curl -s -H "x-relay-token: <RELAY_TOKEN>" http://127.0.0.1:9000/debug/gz/ruleset
```

End debug mode by restarting without `--debug`:

```bash
sudo bash scripts/docker-up-gz.sh
sudo bash scripts/docker-up-hk.sh
```

Then verify the dynamic gate exists:

```bash
sudo nft list table inet dynamic_whitelist
```
## Updates

After pulling new code, run only the command that matches the current VPS:

```bash
sudo bash scripts/docker-up-gz.sh
sudo bash scripts/docker-up-hk.sh
```

## Stop

```bash
sudo docker compose -f docker-compose.gz.yml down
sudo docker compose -f docker-compose.hk.yml down
```

Stopping the Guangzhou container does not automatically remove existing
nftables rules. Restarting it will reconcile rules from `/data/state.json`.

