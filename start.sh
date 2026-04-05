#!/bin/bash
set -e

# Network setup for exit node
modprobe xt_mark 2>/dev/null || true
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.forwarding=1
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
ip6tables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

# Optimize UDP GRO forwarding for Tailscale (see https://tailscale.com/s/ethtool-config-udp-gro)
ethtool -K eth0 rx-udp-gro-forwarding on rx-gro-list off 2>/dev/null || true

# Tailscale — containerboot in background
TS_STATE_DIR=/data/tailscale \
TS_SOCKET=/var/run/tailscale/tailscaled.sock \
TS_EXTRA_ARGS="--advertise-exit-node --ssh" \
TS_HOSTNAME="${TS_HOSTNAME:-${FLY_REGION:-vpn}}" \
  /usr/local/bin/containerboot &

# MTProxy — original entrypoint in background
/run.sh &

# Wait until tailscaled is ready
until tailscale status >/dev/null 2>&1; do
  sleep 1
done

# Retry funnel until it succeeds
until tailscale funnel --bg 8080; do
  sleep 2
done

# ProxyT domain from components
TS_DOMAIN="${TS_HOSTNAME:-${FLY_REGION:-vpn}}.${TS_TAILNET}"

# ProxyT — foreground
exec /app/proxyt serve --http-only --port 8080 --domain "${PROXYT_DOMAIN:-${TS_DOMAIN}}"
