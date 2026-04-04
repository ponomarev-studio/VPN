#!/bin/sh

# Set hostname to FLY_REGION (Fly.io auto-injects FLY_REGION)
export TS_HOSTNAME="${FLY_REGION:-${TS_HOSTNAME:-vpn}}"

# Ensure socket is on shared volume for inter-container communication
export TS_SOCKET="${TS_SOCKET:-/shared/tailscale.sock}"

# Set state directory (persistent volume)
export TS_STATE_DIR="${TS_STATE_DIR:-/data/tailscale}"

# Enable exit node and SSH by default
export TS_EXTRA_ARGS="${TS_EXTRA_ARGS:---advertise-exit-node --ssh}"

# Enable IP forwarding for exit node functionality
modprobe xt_mark 2>/dev/null || true
sysctl -w net.ipv4.ip_forward=1 2>/dev/null || true
sysctl -w net.ipv6.conf.all.forwarding=1 2>/dev/null || true

# Configure NAT masquerading
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE 2>/dev/null || true
ip6tables -t nat -A POSTROUTING -o eth0 -j MASQUERADE 2>/dev/null || true

# Start official Tailscale containerboot
exec /usr/local/bin/containerboot
