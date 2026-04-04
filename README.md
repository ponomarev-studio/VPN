# VPN

Run [Tailscale](https://tailscale.com/) (Exit Node, SSH), [ProxyT](https://github.com/jaxxstorm/proxyt) (via Tailscale Funnel), and [Telegram MTProxy](https://hub.docker.com/r/telegrammessenger/proxy/) together on a single [Fly.io](https://fly.io/) VM as three parallel processes.

No public IP or `*.fly.dev` domain is used — all services are exposed exclusively through Tailscale.

## Architecture

```
Fly VM (single container, three parallel processes)
  ├── tailscaled (background)
  │     ├── Exit Node + SSH
  │     └── State → /data/tailscale (persistent volume)
  ├── proxyt (background)
  │     ├── HTTP proxy on 127.0.0.1:8080
  │     ├── Domain auto-detected from Tailscale
  │     └── Publicly accessible via Tailscale Funnel
  └── mtproto-proxy (foreground)
        ├── Telegram MTProxy on 0.0.0.0:443
        ├── Host extracted from Tailscale for tg:// links
        └── Accessible via Tailscale IP on port 443
```

### How it works

- **Tailscale** connects the VM to your Tailnet as an exit node with SSH access. The domain and IP are extracted and passed to both ProxyT and MTProxy.
- **ProxyT** runs in HTTP-only mode on port 8080, publicly accessible via [Tailscale Funnel](https://tailscale.com/kb/1223/funnel) at `https://<hostname>.<tailnet>.ts.net`.
- **MTProxy** runs the official [`mtproto-proxy`](https://hub.docker.com/r/telegrammessenger/proxy/) binary on port 443. Connection links (`tg://` and `t.me`) use the Tailscale domain and IP. Accessible via the Tailscale IP within the Tailnet.
- **Persistent state** is stored on a Fly volume mounted at `/data` — Tailscale identity, MTProxy secrets, and proxy configs survive restarts without `persist_rootfs`.

## Prerequisites

- [Fly CLI](https://fly.io/docs/flyctl/install/) (`flyctl`)
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

Once deployed, ProxyT will be publicly available via Tailscale Funnel at `https://<region>.<tailnet>.ts.net`. MTProxy connection links (`tg://` and `t.me`) will appear in `fly logs` — they use the Tailscale domain and IP.

## Configuration

### Tailscale

All [official Tailscale Docker environment variables](https://tailscale.com/kb/1282/docker) are supported, plus the legacy `TAILSCALE_AUTHKEY` / `TAILSCALE_HOSTNAME` aliases:

| Variable | Default | Description |
|---|---|---|
| `TS_AUTHKEY` | *(required, secret)* | Tailscale auth key for joining the Tailnet |
| `TS_HOSTNAME` | `${FLY_REGION}` | Tailscale node hostname (defaults to the Fly.io region) |
| `TS_STATE_DIR` | `/data/tailscale` | State directory (on persistent volume) |
| `TS_SOCKET` | `/var/run/tailscale/tailscaled.sock` | Daemon socket path |
| `TS_ROUTES` | *(unset)* | Subnet routes to advertise |
| `TS_ACCEPT_DNS` | *(unset)* | Accept DNS settings from the Tailnet |
| `TS_EXTRA_ARGS` | *(unset)* | Extra arguments for `tailscale up` |
| `TAILSCALE_AUTHKEY` | *(unset)* | Alias for `TS_AUTHKEY` |
| `TAILSCALE_HOSTNAME` | *(unset)* | Alias for `TS_HOSTNAME` |

Exit node (`--advertise-exit-node`) and SSH (`--ssh`) are always enabled.

### MTProxy

All [official MTProxy environment variables](https://hub.docker.com/r/telegrammessenger/proxy/) are supported:

| Variable | Default | Description |
|---|---|---|
| `SECRET` | *(auto-generated)* | MTProxy secret (32 hex chars); persists in `/data/secret` |
| `SECRET_COUNT` | `1` | Number of secrets to auto-generate (1–16) |
| `TAG` | *(none)* | Advertisement tag from [@MTProxybot](https://t.me/mtproxybot) |
| `WORKERS` | `2` | Number of MTProxy worker processes |

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

All persistent state is stored on a [Fly volume](https://fly.io/docs/volumes/) (`vpn_data`) mounted at `/data`:

| Path | Description |
|---|---|
| `/data/tailscale/` | Tailscale node identity and state |
| `/data/secret` | MTProxy secret (auto-generated) |
| `/data/proxy-secret` | MTProxy proxy secret (downloaded from Telegram) |
| `/data/proxy-multi.conf` | MTProxy multi-DC config (downloaded from Telegram) |

This ensures the Tailscale node identity and MTProxy secrets survive restarts and redeploys without `persist_rootfs`.

## Docker Image

The image is based on [`telegrammessenger/proxy:latest`](https://hub.docker.com/r/telegrammessenger/proxy/) (official Telegram MTProxy image) with additional binaries:

| Binary | Source | Type |
|---|---|---|
| `/opt/MTProxy/objs/bin/mtproto-proxy` | Base image | C (native) |
| `/app/tailscaled` | `docker.io/tailscale/tailscale:stable` | Go (static) |
| `/app/tailscale` | `docker.io/tailscale/tailscale:stable` | Go (static) |
| `/app/proxyt` | `ghcr.io/jaxxstorm/proxyt:latest` | Go (static) |

## Security

- No public IP is allocated — `fly.toml` has no `[[services]]` or `[http_service]` section.
- ProxyT is publicly reachable only through Tailscale Funnel (TLS terminated by Tailscale).
- MTProxy is accessible only within the Tailnet (via the node's Tailscale IP).
- Tailscale state is persisted on a Fly volume so the node identity survives restarts.
- IPv4/IPv6 forwarding and NAT masquerading are enabled for exit node functionality.