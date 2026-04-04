#!/bin/bash

# =============================================================================
# VPN: Tailscale + ProxyT + MTProxy — single-container, three parallel processes
# =============================================================================

# === Network Setup (required for Tailscale exit node) ===

modprobe xt_mark 2>/dev/null || true

sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.forwarding=1

iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
ip6tables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

# === Tailscale ===

TS_AUTHKEY="${TS_AUTHKEY:-${TAILSCALE_AUTHKEY}}"
TS_HOSTNAME="${TS_HOSTNAME:-${TAILSCALE_HOSTNAME:-${FLY_REGION:-vpn}}}"
TS_STATE_DIR="${TS_STATE_DIR:-/data/tailscale}"
TS_SOCKET="${TS_SOCKET:-/var/run/tailscale/tailscaled.sock}"

mkdir -p "${TS_STATE_DIR}"

/app/tailscaled \
  --state="${TS_STATE_DIR}/tailscaled.state" \
  --statedir="${TS_STATE_DIR}" \
  --socket="${TS_SOCKET}" &

/app/tailscale up \
  --auth-key="${TS_AUTHKEY}" \
  --hostname="${TS_HOSTNAME}" \
  --advertise-exit-node \
  --ssh \
  ${TS_ROUTES:+--advertise-routes="${TS_ROUTES}"} \
  ${TS_ACCEPT_DNS:+--accept-dns="${TS_ACCEPT_DNS}"} \
  ${TS_EXTRA_ARGS}

# Extract Tailscale domain and IP
TS_DOMAIN=$(/app/tailscale --socket="${TS_SOCKET}" status --json | grep -o '"DNSName":"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')
TS_IPV4=$(/app/tailscale --socket="${TS_SOCKET}" ip -4 2>/dev/null || true)

echo "Tailscale domain: ${TS_DOMAIN}"
echo "Tailscale IP: ${TS_IPV4}"

# === ProxyT (via Tailscale Funnel) ===

/app/tailscale --socket="${TS_SOCKET}" funnel --bg 8080

PROXYT_DOMAIN="${PROXYT_DOMAIN:-${TS_DOMAIN}}"
PROXYT_DOMAIN="${PROXYT_DOMAIN:-${TS_HOSTNAME}}"

echo "Starting ProxyT with domain: ${PROXYT_DOMAIN}"
/app/proxyt serve --http-only --port 8080 --domain "${PROXYT_DOMAIN}" &

# === MTProxy ===

# Download proxy configs
curl -s https://core.telegram.org/getProxySecret -o /data/proxy-secret
curl -s https://core.telegram.org/getProxyConfig -o /data/proxy-multi.conf

# Handle secrets
if [ -z "${SECRET}" ]; then
  if [ -f /data/secret ]; then
    SECRET=$(cat /data/secret)
  else
    SECRET=$(head -c 16 /dev/urandom | xxd -ps)
    i=2
    while [ "$i" -le "${SECRET_COUNT:-1}" ]; do
      SECRET="${SECRET},$(head -c 16 /dev/urandom | xxd -ps)"
      i=$((i + 1))
    done
    echo "${SECRET}" > /data/secret
  fi
fi

# Build -S flags for mtproto-proxy
SECRET_FLAGS=""
IFS=',' read -ra SECRETS <<< "${SECRET}"
for s in "${SECRETS[@]}"; do
  SECRET_FLAGS="${SECRET_FLAGS} -S ${s}"
done
FIRST_SECRET="${SECRETS[0]}"

# Use Tailscale domain for MTProxy links
MTPROXY_HOST="${TS_DOMAIN:-${TS_HOSTNAME}}"

echo ""
echo "==============================="
echo "ProxyT: https://${PROXYT_DOMAIN}"
echo ""
echo "MTProxy (domain):"
echo "  tg://proxy?server=${MTPROXY_HOST}&port=443&secret=dd${FIRST_SECRET}"
echo "  https://t.me/proxy?server=${MTPROXY_HOST}&port=443&secret=dd${FIRST_SECRET}"
if [ -n "${TS_IPV4}" ]; then
  echo ""
  echo "MTProxy (IP):"
  echo "  tg://proxy?server=${TS_IPV4}&port=443&secret=dd${FIRST_SECRET}"
  echo "  https://t.me/proxy?server=${TS_IPV4}&port=443&secret=dd${FIRST_SECRET}"
fi
echo "==============================="
echo ""

# Start MTProxy (foreground — main process)
exec /opt/MTProxy/objs/bin/mtproto-proxy \
  -u nobody -p 8888 -H 443 \
  ${SECRET_FLAGS} \
  --aes-pwd /data/proxy-secret \
  /data/proxy-multi.conf \
  -M "${WORKERS:-2}" \
  ${TAG:+--proxy-tag "${TAG}"}
