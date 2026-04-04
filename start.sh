#!/bin/bash

# Network setup for exit node
modprobe xt_mark 2>/dev/null || true
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.forwarding=1
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
ip6tables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

# Tailscale — original entrypoint (containerboot) in background
TS_STATE_DIR=/data/tailscale \
TS_SOCKET=/var/run/tailscale/tailscaled.sock \
TS_EXTRA_ARGS="--advertise-exit-node --ssh" \
TS_HOSTNAME="${TS_HOSTNAME:-${FLY_REGION:-vpn}}" \
  /usr/local/bin/containerboot &

# Wait for Tailscale to connect
echo "Waiting for Tailscale..."
until tailscale status >/dev/null 2>&1; do sleep 0.5; done

# Extract Tailscale domain
TS_DOMAIN=$(tailscale status --json | grep -o '"DNSName":"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')

# MTProxy — original entrypoint (/run.sh) in background
IP=$TS_DOMAIN /run.sh &

# ProxyT — via Tailscale Funnel
tailscale funnel --bg 8080

# ProxyT — original entrypoint (foreground)
exec /app/proxyt serve --http-only --port 8080 --domain "${PROXYT_DOMAIN:-${TS_DOMAIN}}"
