#!/bin/bash

# Network setup for Tailscale exit node
modprobe xt_mark 2>/dev/null || true
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.forwarding=1
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
ip6tables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

# Tailscale
mkdir -p /data/tailscale

/app/tailscaled --state=/data/tailscale/tailscaled.state --statedir=/data/tailscale --socket=/var/run/tailscale/tailscaled.sock &

echo "Waiting for tailscaled..."
while [ ! -S /var/run/tailscale/tailscaled.sock ]; do sleep 0.2; done

/app/tailscale up \
  --auth-key="${TS_AUTHKEY}" \
  --hostname="${TS_HOSTNAME:-${FLY_REGION:-vpn}}" \
  --advertise-exit-node \
  --ssh

# Extract Tailscale domain
TS_DOMAIN=$(/app/tailscale status --json | grep -o '"DNSName":"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')

echo "Tailscale: ${TS_DOMAIN}"

# ProxyT (via Tailscale Funnel)
/app/tailscale funnel --bg 8080
/app/proxyt serve --http-only --port 8080 --domain "${PROXYT_DOMAIN:-${TS_DOMAIN}}" &

echo "ProxyT: https://${PROXYT_DOMAIN:-${TS_DOMAIN}}"
echo "MTProxy: ${TS_DOMAIN}:${PORT:-443}"

# MTProxy — set IP for the original entrypoint and delegate to /run.sh
export IP=$(/app/tailscale ip -4)

exec /run.sh
