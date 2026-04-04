#!/bin/bash

# Graceful shutdown handler
PIDS=()
shutdown() {
  echo "Received shutdown signal, stopping services..."
  for pid in "${PIDS[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null
    fi
  done
  wait "${PIDS[@]}" 2>/dev/null
  exit 0
}
trap shutdown SIGINT SIGTERM

# Network setup for exit node
modprobe xt_mark 2>/dev/null || true
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.forwarding=1
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
ip6tables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

# Optimize UDP GRO forwarding for Tailscale (see https://tailscale.com/s/ethtool-config-udp-gro)
ethtool -K eth0 rx-udp-gro-forwarding on rx-gro-list off 2>/dev/null || true

# Tailscale — original entrypoint (containerboot) in background
TS_STATE_DIR=/data/tailscale \
TS_SOCKET=/var/run/tailscale/tailscaled.sock \
TS_EXTRA_ARGS="--advertise-exit-node --ssh" \
TS_HOSTNAME="${TS_HOSTNAME:-${FLY_REGION:-vpn}}" \
  /usr/local/bin/containerboot &
CONTAINERBOOT_PID=$!
PIDS+=("$CONTAINERBOOT_PID")

# Wait for Tailscale to connect
echo "Waiting for Tailscale..."
TAILSCALE_STATUS_TIMEOUT="${TAILSCALE_STATUS_TIMEOUT:-60}"
START_TIME=$SECONDS
while ! tailscale status >/dev/null 2>&1; do
  if ! kill -0 "$CONTAINERBOOT_PID" 2>/dev/null; then
    echo "Error: containerboot exited before Tailscale became ready." >&2
    exit 1
  fi

  if [ $((SECONDS - START_TIME)) -ge "$TAILSCALE_STATUS_TIMEOUT" ]; then
    echo "Error: Tailscale did not become ready within ${TAILSCALE_STATUS_TIMEOUT}s." >&2
    exit 1
  fi

  sleep 0.5
done

# Extract Tailscale domain
TS_DOMAIN=$(tailscale status --json | jq -r '.Self.DNSName | rtrimstr(".")')

# MTProxy — original entrypoint (/run.sh) in background
export IP=$TS_DOMAIN
/run.sh &
PIDS+=("$!")

# ProxyT — via Tailscale Funnel
if ! tailscale funnel --bg 8080; then
  echo "ERROR: Failed to enable Tailscale Funnel on port 8080. Check Funnel ACLs, permissions, and Tailscale configuration." >&2
  exit 1
fi

# ProxyT — in background (not exec, so the shell can handle signals)
/app/proxyt serve --http-only --port 8080 --domain "${PROXYT_DOMAIN:-${TS_DOMAIN}}" &
PIDS+=("$!")

# Wait for any tracked child to exit
wait -n "${PIDS[@]}" 2>/dev/null
echo "A child process exited unexpectedly, shutting down..."
shutdown
