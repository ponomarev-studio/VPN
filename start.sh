#!/bin/sh
set -e

tailscaled \
  --state=/data/tailscale/tailscaled.state \
  --socket=/var/run/tailscale/tailscaled.sock \
  --tun=userspace-networking &

sleep 2

tailscale up \
  --auth-key="$TS_AUTHKEY" \
  --hostname="$TS_HOSTNAME"

proxyt serve \
  --http-only \
  --port 3000 \
  --domain "${PROXYT_DOMAIN:-${TS_HOSTNAME}.${TS_TAILNET}}" &

sleep 1

tailscale debug force-prefer-derp 14

tailscale funnel --bg 3000

wait
