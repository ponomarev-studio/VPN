# VPN

Run [Tailscale](https://tailscale.com/) (Exit Node, SSH), [ProxyT](https://github.com/jaxxstorm/proxyt) (via Tailscale Funnel), and [Telegram MTProxy](https://hub.docker.com/r/telegrammessenger/proxy/) together on a single [Fly.io](https://fly.io/) Machine using [multi-container setup](https://fly.io/docs/machines/guides-examples/multi-container-machines/).

No public IP or `*.fly.dev` domain is used — all services are exposed exclusively through Tailscale.

## Architecture

```
Fly Machine (multi-container, shared network)
  ├── tailscale (docker.io/tailscale/tailscale:stable)
  │     ├── Exit Node + SSH
  │     ├── Funnel → 127.0.0.1:8080 (ProxyT)
  │     └── State → /data/tailscale (persistent volume)
  ├── proxyt (built from Dockerfile)
  │     ├── HTTP proxy on 127.0.0.1:8080
  │     ├── Domain auto-detected from Tailscale
  │     └── Publicly accessible via Tailscale Funnel
  └── mtproxy (telegrammessenger/proxy:latest)
        ├── Telegram MTProxy on 0.0.0.0:443
        └── Accessible via Tailscale IP on port 443
```

### How it works

- **Tailscale** connects the Machine to your Tailnet as an exit node with SSH access. A shared socket (`/shared/tailscale.sock`) allows other containers to interact with the Tailscale daemon.
- **ProxyT** waits for Tailscale to become healthy, configures [Tailscale Funnel](https://tailscale.com/kb/1223/funnel) to expose port 8080, auto-detects its domain from Tailscale, and runs in HTTP-only mode. It is publicly accessible at `https://<hostname>.<tailnet>.ts.net`.
- **MTProxy** runs the official Telegram MTProxy image unmodified. It listens on port 443 and is accessible via the Tailscale IP within the Tailnet.
- **Inter-container communication** uses a shared temporary volume (`/shared`) for the Tailscale socket, and a persistent Fly volume (`/data`) for Tailscale and MTProxy state.

## Prerequisites

- [Fly CLI](https://fly.io/docs/flyctl/install/) (`flyctl`) v0.3.147+
- A [Fly.io](https://fly.io/) account
- A [Tailscale](https://tailscale.com/) account with an [auth key](https://tailscale.com/kb/1085/auth-keys)

## Setup

1. **Create the Fly app:**

   ```sh
   fly apps create vpn-ps
   ```

2. **Set the Tailscale auth key as a secret:**

   ```sh
   fly secrets set TS_AUTHKEY=tskey-auth-...
   ```

3. **Optionally set MTProxy secrets:**

   ```sh
   fly secrets set SECRET=<32-hex-chars> TAG=<your-tag>
   ```

4. **Deploy:**

   ```sh
   fly deploy
   ```

Once deployed, ProxyT will be publicly available via Tailscale Funnel at `https://<region>.<tailnet>.ts.net`. MTProxy will be accessible via the Tailscale IP on port 443. View logs with `fly logs` to see the MTProxy connection links.

## Configuration

### Tailscale

The Tailscale container uses the official [`tailscale/tailscale:stable`](https://hub.docker.com/r/tailscale/tailscale) image. All [official environment variables](https://tailscale.com/kb/1282/docker) are supported:

| Variable | Default | Description |
|---|---|---|
| `TS_AUTHKEY` | *(required, secret)* | Tailscale auth key for joining the Tailnet |
| `TS_HOSTNAME` | `${FLY_REGION}` | Tailscale node hostname (defaults to the Fly.io region) |
| `TS_EXTRA_ARGS` | `--advertise-exit-node --ssh` | Extra arguments for `tailscale set` |
| `TS_STATE_DIR` | `/data/tailscale` | State directory (on persistent volume) |
| `TS_SOCKET` | `/shared/tailscale.sock` | Daemon socket path (on shared volume) |
| `TS_USERSPACE` | *(unset)* | Set to `true` for userspace networking |
| `TS_ROUTES` | *(unset)* | Subnet routes to advertise |
| `TS_SERVE_CONFIG` | *(unset)* | Path to serve/funnel config JSON |
| `TS_DEST_IP` | *(unset)* | Destination IP for proxy mode |

### MTProxy

The MTProxy container uses the official [`telegrammessenger/proxy`](https://hub.docker.com/r/telegrammessenger/proxy/) image. All official environment variables are supported:

| Variable | Default | Description |
|---|---|---|
| `SECRET` | *(auto-generated)* | MTProxy secret (32 hex chars); persists in `/data/secret` |
| `SECRET_COUNT` | `1` | Number of secrets to auto-generate (1–16) |
| `TAG` | *(none)* | Advertisement tag from [@MTProxybot](https://t.me/mtproxybot) |
| `WORKERS` | `2` | Number of MTProxy worker processes |
| `DEBUG` | *(none)* | Set to any value to enable debug output |

### ProxyT

| Variable | Default | Description |
|---|---|---|
| `PROXYT_DOMAIN` | *(auto-detected from Tailscale)* | ProxyT domain override |

### Instance Parameters

| Setting | Value | Notes |
|---|---|---|
| `app` | `vpn-ps` | Fly app name |
| `primary_region` | `ams` | Fly.io [region](https://fly.io/docs/reference/regions/) |
| `memory_mb` | `256` | VM memory |
| `swap_size_mb` | `256` | Swap size |
| `cpus` | `1` | Shared vCPU |
| `restart` | `always` | Restart policy |
| `persist_rootfs` | *(disabled)* | Not used; state is on a Fly volume |

## Volume

Tailscale and MTProxy state is persisted on a [Fly volume](https://fly.io/docs/volumes/) mounted at `/data`. The volume is automatically created on first deploy via the `[mounts]` section in `fly.toml`.

The persistent volume stores:
- `/data/tailscale/` — Tailscale node identity and state
- `/data/secret` — MTProxy secret (auto-generated)

This ensures the Tailscale node identity and MTProxy secret survive restarts and redeploys without `persist_rootfs`.

## Multi-container Setup

This project uses Fly.io [multi-container Machines](https://fly.io/docs/machines/guides-examples/multi-container-machines/) with three containers running on a single VM:

| Container | Image | Role |
|---|---|---|
| `tailscale` | `docker.io/tailscale/tailscale:stable` | Tailscale daemon (exit node, SSH, funnel) |
| `proxyt` | Built from `Dockerfile` | ProxyT HTTP proxy (exposed via funnel) |
| `mtproxy` | `telegrammessenger/proxy:latest` | Telegram MTProxy (accessible via Tailnet) |

The `cli-config.json` defines the container configuration, dependencies, health checks, and shared volumes. The `fly.toml` references it via `[experimental] machine_config`.

### Container Dependencies

```
tailscale ──(healthy)──► proxyt
tailscale ──(started)──► mtproxy
```

- **ProxyT** waits for Tailscale to pass its health check before starting.
- **MTProxy** starts as soon as the Tailscale container has started.

### Shared Volumes

| Volume | Type | Path | Purpose |
|---|---|---|---|
| `shared` | Temp dir (10 MB) | `/shared` | Tailscale socket for inter-container communication |
| `tailscale_data` | Fly volume | `/data` | Persistent state for Tailscale and MTProxy |

## Security

- No public IP is allocated — `fly.toml` has no `[[services]]` or `[http_service]` section.
- ProxyT is publicly reachable only through Tailscale Funnel (TLS terminated by Tailscale).
- MTProxy is accessible only within the Tailnet (via the node's Tailscale IP).
- Tailscale state is persisted on a Fly volume so the node identity survives restarts.
- IPv4/IPv6 forwarding and NAT masquerading are enabled for exit node functionality.
- Each container runs in its own isolated process tree.