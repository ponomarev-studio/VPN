#!/bin/sh
set -e

modprobe xt_mark

echo 'net.ipv4.ip_forward = 1' | tee -a /etc/sysctl.conf
echo 'net.ipv6.conf.all.forwarding = 1' | tee -a /etc/sysctl.conf
sysctl -p /etc/sysctl.conf

iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
ip6tables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

tailscaled --state=/data/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock --socks5-server=:1080 --outbound-http-proxy-listen=:1080 &
tailscale up --auth-key=${TS_AUTHKEY} --hostname=${FLY_REGION:-vpn} --advertise-exit-node --ssh --reset

tailscale funnel --bg 3000

TS_DOMAIN="${FLY_REGION:-vpn}.${TS_TAILNET}"

exec proxyt serve --http-only --port 3000 --domain "${PROXYT_DOMAIN:-${TS_DOMAIN}}"
