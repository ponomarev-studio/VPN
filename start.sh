#!/bin/sh

TS_SOCKET="${TS_SOCKET:-/shared/tailscale.sock}"

# Wait for Tailscale to be ready
echo "Waiting for Tailscale..."
until /app/tailscale --socket="${TS_SOCKET}" status >/dev/null 2>&1; do
  sleep 1
done

# Configure Tailscale Funnel to expose ProxyT publicly
/app/tailscale --socket="${TS_SOCKET}" funnel --bg 8080

# Extract domain from Tailscale DNS name
PROXYT_DOMAIN=${PROXYT_DOMAIN:-$(/app/tailscale --socket="${TS_SOCKET}" status --json | grep -o '"DNSName":"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')}
PROXYT_DOMAIN=${PROXYT_DOMAIN:-${FLY_REGION:-proxyt}}

echo "Starting ProxyT with domain: ${PROXYT_DOMAIN}"
exec /app/proxyt serve --http-only --port 8080 --domain "${PROXYT_DOMAIN}"
