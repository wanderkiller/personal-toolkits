# Two VPS Deployment

This guide covers only the two VPS machines:

- HK VPS: public relay, receives FC requests and pushes to Guangzhou.
- Guangzhou VPS: private CCN-side agent, updates public inbound nftables allow rules.

Alibaba Cloud FC deployment is intentionally not repeated here.

## 1. Guangzhou VPS

Clone or copy this directory to the Guangzhou machine, then install the agent:

```bash
cd dynamic-whitelist
sudo bash scripts/install-gz-agent.sh
sudo vim /etc/dynamic-whitelist/gz-agent.env
```

Example `/etc/dynamic-whitelist/gz-agent.env`:

```text
GZ_AGENT_HOST=10.0.0.2
GZ_AGENT_PORT=9001
GZ_AGENT_TOKEN=replace-with-agent-token
PUBLIC_INTERFACE=auto
PROTECT_TCP=true
PROTECT_UDP=true
ALLOWLIST_MAX_IPS=6
ALLOWLIST_TTL_SECONDS=86400
ALLOWLIST_STATE=/var/lib/dynamic-whitelist/state.json
NFT_BIN=nft
NFT_FAMILY=inet
NFT_TABLE=dynamic_whitelist
NFT_ALLOW_SET=allow4
NFT_CHAIN=forward_guard
NFT_PRIORITY=-150
RECONCILE_INTERVAL_SECONDS=300
```

Use the Guangzhou CCN private IP for `GZ_AGENT_HOST`. Do not use `0.0.0.0`
unless the VPS has no public interface exposed to that bind.

Start and check:

```bash
sudo systemctl start gz-agent
sudo systemctl status gz-agent --no-pager
sudo ss -lntp | grep 9001
sudo nft list table inet dynamic_whitelist
sudo nft list table inet dynamic_whitelist
```

The agent runs as root because it updates nftables. It rebuilds its dedicated nftables table on startup and every `RECONCILE_INTERVAL_SECONDS`, so a firewall reload or
reboot is corrected automatically.

## 2. HK Relay VPS

Install the relay:

```bash
cd dynamic-whitelist
sudo bash scripts/install-hk-relay.sh
sudo vim /etc/dynamic-whitelist/hk-relay.env
```

Recommended `/etc/dynamic-whitelist/hk-relay.env` when using Nginx TLS:

```text
HK_RELAY_HOST=127.0.0.1
HK_RELAY_PORT=9000
RELAY_TOKEN=replace-with-relay-token
GZ_AGENT_URL=http://10.0.0.2:9001/v1/allow
GZ_AGENT_TOKEN=replace-with-agent-token
GZ_AGENT_TIMEOUT=2.0
HK_RELAY_QUEUE_MAX=256
```

Start and check the local relay:

```bash
sudo systemctl start hk-relay
sudo systemctl status hk-relay --no-pager
curl -s http://127.0.0.1:9000/healthz
```

## 3. HK HTTPS Front

Recommended: expose the HK relay through Nginx HTTPS and keep the Python relay
bound to `127.0.0.1`.

Install Nginx and a certificate using your preferred ACME flow, then copy:

```bash
sudo cp nginx/hk-relay.conf.example /etc/nginx/sites-available/hk-relay.conf
sudo vim /etc/nginx/sites-available/hk-relay.conf
sudo ln -s /etc/nginx/sites-available/hk-relay.conf /etc/nginx/sites-enabled/hk-relay.conf
sudo nginx -t
sudo systemctl reload nginx
```

FC should use:

```text
RELAY_URL=https://hk-relay.example.com/v1/allow
RELAY_TOKEN=replace-with-relay-token
```

Minimal test-only option: skip Nginx, bind `HK_RELAY_HOST=0.0.0.0`, and use
`http://HK_PUBLIC_IP:9000/v1/allow` from FC. This is not recommended for long
term use because the relay token crosses the public network without TLS.

## 4. End-to-end Tests

From HK VPS, test direct CCN delivery to Guangzhou:

```bash
curl -sS \
  -H 'content-type: application/json' \
  -H 'x-agent-token: replace-with-agent-token' \
  -d '{"ip":"1.1.1.1","device":"manual"}' \
  http://10.0.0.2:9001/v1/allow
```

From HK VPS, test relay wait mode:

```bash
curl -sS \
  -H 'content-type: application/json' \
  -H 'x-relay-token: replace-with-relay-token' \
  -d '{"ip":"1.1.1.1","device":"manual","mode":"wait"}' \
  http://127.0.0.1:9000/v1/allow
```

On Guangzhou VPS, verify:

```bash
sudo nft list table inet dynamic_whitelist
sudo cat /var/lib/dynamic-whitelist/state.json
```

## 5. Keepalive Model

Server-side keepalive:

- `hk-relay.service` uses `Restart=always`.
- `gz-agent.service` uses `Restart=always`.
- Guangzhou agent rebuilds nftables on startup.
- Guangzhou agent reconciles nftables and removes expired state every 300s by default.

Client-side keepalive:

- Stash / Quantumult X / Mihomo should call FC every 4 minutes.
- FC fast mode returns once HK Relay accepts the job.
- Manual first-connect can use `mode=wait` to confirm Guangzhou nftables has updated.

The HK relay queue is in memory. If HK Relay restarts after accepting a fast job
but before forwarding it, that single job can be lost. This is acceptable because
clients repeat every 4 minutes and the Guangzhou TTL is 24 hours. Use `mode=wait`
for manual checks when immediate confirmation matters.

