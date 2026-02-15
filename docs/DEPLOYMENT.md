# Deployment Guide

This guide covers deploying Fish Market as a systemd service on a Linux host, connecting to a local OpenClaw gateway behind Cloudflare Tunnel.

## Prerequisites

- **Erlang/OTP 28.3.1** and **Elixir 1.19.5-otp-28** installed (via asdf or system packages)
- A running **OpenClaw gateway** (typically `openclaw-gateway.service`)
- **Cloudflare Tunnel** terminating TLS and forwarding to the Fish Market HTTP port

## 1. Clone and Build

```bash
cd ~
git clone https://demeter.radi.ws/evadne/fish_market.git
cd fish_market

# Ensure correct Erlang/Elixir are on PATH
# If using asdf:
#   export PATH="$HOME/.asdf/installs/erlang/28.3.1/bin:$HOME/.asdf/installs/elixir/1.19.5-otp-28/bin:$PATH"

# Install dependencies (prod only)
MIX_ENV=prod mix deps.get --only prod

# Install asset build tools (tailwind, esbuild)
MIX_ENV=prod mix assets.setup

# Build and fingerprint static assets
MIX_ENV=prod mix assets.deploy

# Build the OTP release
MIX_ENV=prod mix release fish_market --overwrite
```

This produces a self-contained release at `_build/prod/rel/fish_market/`.

## 2. Generate Secrets

```bash
mix phx.gen.secret
```

Save the output — you'll need it for `SECRET_KEY_BASE` below.

## 3. Create the systemd Unit

Create `~/.config/systemd/user/fish-market.service`:

```ini
[Unit]
Description=Fish Market (Phoenix/LiveView OpenClaw Frontend)
After=network-online.target openclaw-gateway.service
Wants=network-online.target

[Service]
Type=exec
WorkingDirectory=/home/YOUR_USER/fish_market
ExecStart=/home/YOUR_USER/fish_market/_build/prod/rel/fish_market/bin/fish_market start
ExecStop=/home/YOUR_USER/fish_market/_build/prod/rel/fish_market/bin/fish_market stop
Restart=always
RestartSec=5
KillMode=process

# Paths — adjust to your Erlang/Elixir installation
Environment=HOME=/home/YOUR_USER
Environment="PATH=/home/YOUR_USER/.asdf/installs/erlang/28.3.1/bin:/home/YOUR_USER/.asdf/installs/elixir/1.19.5-otp-28/bin:/usr/local/bin:/usr/bin:/bin"

# Application config
Environment=PORT=4848
Environment=HOST=your.domain.example
Environment=URL_PORT=443
Environment=SECRET_KEY_BASE=<output of mix phx.gen.secret>

# OpenClaw gateway connection
Environment=OPENCLAW_GATEWAY_URL=ws://127.0.0.1:18789
Environment=OPENCLAW_GATEWAY_PASSWORD=<your gateway password>

# Erlang cookie for distributed features (remote shell, etc.)
Environment=RELEASE_COOKIE=fish_market_prod

[Install]
WantedBy=default.target
```

Replace all `YOUR_USER` and placeholder values with your actual configuration.

### Notes on the unit file

- **`Type=exec`** — the BEAM starts directly (not forked), systemd tracks the main process.
- **`After=openclaw-gateway.service`** — ensures the gateway is started first. Fish Market reconnects automatically if the gateway restarts, but starting in order avoids transient errors.
- **`KillMode=process`** — kills only the main BEAM process; the BEAM handles shutting down its own children.
- **`Restart=always`** — the service restarts on any exit (crash, OOM, manual stop via `bin/fish_market stop` will also restart — use `systemctl --user stop` instead).
- **`PORT=4848`** — the HTTP listen port. Avoid 4000 (commonly used by other dev servers).
- **`URL_PORT=443`** — tells Phoenix the external-facing port is 443 (behind Cloudflare). This affects generated URLs and redirects.
- **`URL_SCHEME`** — auto-detected as `https` when `URL_PORT=443`. Set explicitly if needed.
- **`RELEASE_COOKIE`** — required for `bin/fish_market remote` (IEx remote shell). Pick any stable string.

## 4. Enable and Start

```bash
# Reload unit files
systemctl --user daemon-reload

# Enable (start on boot) and start now
systemctl --user enable --now fish-market.service

# Verify it's running
systemctl --user status fish-market.service

# Follow logs
journalctl --user -u fish-market.service -f
```

For the service to start on boot without an active login session:

```bash
sudo loginctl enable-linger YOUR_USER
```

## 5. Verify

```bash
# HTTP health check
curl -s -o /dev/null -w '%{http_code}' http://localhost:4848
# Expected: 200

# Check gateway connection in logs
journalctl --user -u fish-market.service --no-pager | grep -i gateway
# Look for: "Connected to OpenClaw gateway"
```

## 6. Cloudflare Tunnel

Configure your Cloudflare Tunnel to forward traffic to `http://localhost:4848`.

Fish Market serves plain HTTP — Cloudflare terminates TLS. The app handles the `x-forwarded-proto` header correctly via Phoenix's `force_ssl` with `rewrite_on: [:x_forwarded_proto]`, so HTTPS redirects work without the app needing to know about certificates.

## Updating

To deploy a new version:

```bash
cd ~/fish_market
git pull

# Rebuild
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix assets.setup
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release fish_market --overwrite

# Restart the service
systemctl --user restart fish-market.service
```

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Service fails immediately | Missing env var | Check `journalctl --user -u fish-market.service` for the missing variable name |
| `Protocol 'inet_tcp': register/listen error` | Port already in use | Check `ss -tlnp \| grep 4848` and change `PORT` |
| Gateway not connecting | Wrong URL or password | Verify `OPENCLAW_GATEWAY_URL` and `OPENCLAW_GATEWAY_PASSWORD` match your gateway config |
| `remote` shell won't connect | Cookie mismatch | Ensure `RELEASE_COOKIE` matches between the running service and your shell |
| Assets not loading (404) | Stale build | Re-run `mix assets.deploy` and `mix release` |

## Environment Variables Reference

| Variable | Required | Default | Description |
|---|---|---|---|
| `SECRET_KEY_BASE` | **Yes** | — | Generate with `mix phx.gen.secret` |
| `OPENCLAW_GATEWAY_URL` | **Yes** | — | WebSocket URL, e.g. `ws://127.0.0.1:18789` |
| `OPENCLAW_GATEWAY_TOKEN` | One of token/password | — | Gateway auth token |
| `OPENCLAW_GATEWAY_PASSWORD` | One of token/password | — | Gateway auth password |
| `PORT` | No | `4000` | HTTP listen port |
| `HOST` | No | `localhost` | Public hostname for URL generation |
| `URL_PORT` | No | Same as `PORT` | Public-facing port (e.g. `443` behind reverse proxy) |
| `URL_SCHEME` | No | Auto (`https` if URL_PORT=443) | URL scheme (`http` or `https`) |
| `DNS_CLUSTER_QUERY` | No | — | DNS cluster discovery query |
| `RELEASE_COOKIE` | No | Random | Erlang distribution cookie |
