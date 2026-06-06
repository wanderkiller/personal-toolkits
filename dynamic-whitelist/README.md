
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
# Dynamic Whitelist

Dynamic IP authorization for a Guangzhou VPS that keeps existing nftables DNAT/MASQUERADE forwarding intact.

The Guangzhou VPS keeps 18650/tcp open for SSH and forwards selected public ports through existing nftables DNAT/MASQUERADE rules. A client
periodically calls an Alibaba Cloud Function Compute endpoint in Hong Kong. The
function extracts the client public IP and asks the Hong Kong relay to push it
through the CCN private network to the Guangzhou agent. The Guangzhou agent then
refreshes a small nftables allowlist in an isolated forward hook table.

```text
Client -> Alibaba Cloud FC (Hong Kong) -> HK Relay -> CCN -> Guangzhou Agent
```

## Design

- The client uses one fixed token.
- The relay and agent use fixed internal tokens.
- The Guangzhou allowlist keeps at most 6 active IPs.
- Each refresh extends the IP expiry to 24 hours.
- When a 7th active IP appears, the least recently refreshed IP is evicted.
- Guangzhou returns TCP RST for non-allowlisted forwarded TCP traffic before it reaches the HK SS2022 server.
- The FC fast path returns once the HK relay has accepted the update.
- The optional wait path blocks until the Guangzhou agent has updated its isolated nftables table.

## Files

- `fc/index.js` - Alibaba Cloud FC Node.js HTTP trigger handler.
- `hk-relay/hk_relay.py` - HK relay service, no third-party dependencies.
- `gz-agent/gz_agent.py` - Guangzhou whitelist agent, no third-party dependencies.
- `systemd/*.service` - example systemd units.
- `clients/*` - Stash, Quantumult X, and Mihomo/Clash Verge keepalive templates.

## FC Environment

```text
CLIENT_TOKEN=change-me-client-token
RELAY_URL=https://hk-relay.example.com/v1/allow
RELAY_TOKEN=change-me-relay-token
RELAY_TIMEOUT_MS=1200
```

Use handler `index.handler` on Node.js 18 or 20. Configure minimum instances to
`1` if you want stable low latency.

## HK Relay Environment

```text
HK_RELAY_HOST=127.0.0.1
HK_RELAY_PORT=9000
RELAY_TOKEN=change-me-relay-token
GZ_AGENT_URL=http://10.0.0.2:9001/v1/allow
GZ_AGENT_TOKEN=change-me-agent-token
GZ_AGENT_TIMEOUT=2.0
HK_RELAY_DEBUG_ENDPOINTS=false
```

## Guangzhou Agent Environment

```text
GZ_AGENT_HOST=10.0.0.2
GZ_AGENT_PORT=9001
GZ_AGENT_TOKEN=change-me-agent-token
PUBLIC_INTERFACE=auto
PROTECT_TCP=true
PROTECT_UDP=true
FIREWALL_ENABLED=true
DEBUG_ENDPOINTS=false
ALLOWLIST_MAX_IPS=6
ALLOWLIST_TTL_SECONDS=86400
ALLOWLIST_STATE=/var/lib/dynamic-whitelist/state.json
NFT_BIN=nft
NFT_FAMILY=inet
NFT_TABLE=dynamic_whitelist
NFT_ALLOW_SET=allow4
NFT_CHAIN=forward_guard
NFT_PRIORITY=-150
```

The Guangzhou agent owns only `table inet dynamic_whitelist`. It does not touch existing DNAT, MASQUERADE, Docker, or INPUT rules. Keep the existing INPUT rule that opens `18650/tcp` for SSH.

## Client Rule

The whitelist endpoint must bypass the proxy so FC sees the real client IP.

```text
wl.example.com -> DIRECT
```

## Deployment Order

Docker deployment is the primary path for both VPS machines. Because this repo is private, deploy by tarball unless you intentionally configure GitHub deploy keys.

1. Package locally and upload to both VPS machines. See `PRIVATE-REPO-DEPLOY.md`.
2. On Guangzhou VPS, edit `env/gz-agent.env`, then run:

   ```bash
   sudo bash scripts/docker-up-gz.sh
   ```

3. On HK Relay VPS, edit `env/hk-relay.env`, then run:

   ```bash
   sudo bash scripts/docker-up-hk.sh
   ```

4. Put Nginx HTTPS in front of HK Relay. See `nginx/hk-relay.conf.example`.
5. Deploy `fc/index.js` to Alibaba Cloud FC in Hong Kong with handler `index.handler`.
6. Add the client template for Stash, Quantumult X, or Mihomo/Clash Verge.

Fast mode:

```text
https://wl.example.com/pulse/<CLIENT_TOKEN>?device=stash&mode=fast
```

Wait mode:

```text
https://wl.example.com/pulse/<CLIENT_TOKEN>?device=manual&mode=wait
```

Legacy systemd examples are kept under `systemd/`, but Docker is the tested deployment path.

## Debug 联调模式
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

For VPS integration, start both Docker services with `--debug` first:

```bash
sudo bash scripts/docker-up-gz.sh --debug
sudo bash scripts/docker-up-hk.sh --debug
```

In this mode Guangzhou still accepts `/v1/allow`, persists the 6-IP/24h state, and can preview the nft rules, but `FIREWALL_ENABLED=false` prevents applying the dynamic nft forward gate. The agent also attempts to delete only its own `table inet dynamic_whitelist`, leaving existing DNAT/MASQUERADE/INPUT rules untouched.

Useful debug checks:

```bash
curl -s -H "x-agent-token: <GZ_AGENT_TOKEN>" http://10.0.0.2:9001/debug/state
curl -s -H "x-agent-token: <GZ_AGENT_TOKEN>" http://10.0.0.2:9001/debug/ruleset
curl -s -H "x-relay-token: <RELAY_TOKEN>" http://127.0.0.1:9000/debug/status
curl -s -H "x-relay-token: <RELAY_TOKEN>" http://127.0.0.1:9000/debug/gz/state
```

After CCN and relay forwarding are confirmed, restart without `--debug` to enable the actual dynamic gate.
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