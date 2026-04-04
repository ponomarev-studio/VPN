# Based on the official Telegram MTProxy image (Debian-based)
# Includes: mtproto-proxy binary + /run.sh entrypoint
# https://hub.docker.com/r/telegrammessenger/proxy
FROM telegrammessenger/proxy:latest

# Fix archived Debian Jessie repos and install runtime dependencies
RUN echo "deb http://archive.debian.org/debian jessie main" > /etc/apt/sources.list && \
    apt-get -o Acquire::Check-Valid-Until=false update && \
    apt-get install -y --allow-unauthenticated --no-install-recommends \
        iptables kmod ca-certificates ethtool && \
    rm -rf /var/lib/apt/lists/*

# Copy Tailscale binaries (full containerboot + daemon + CLI)
# https://hub.docker.com/r/tailscale/tailscale
COPY --from=docker.io/tailscale/tailscale:latest /usr/local/bin/containerboot /usr/local/bin/containerboot
COPY --from=docker.io/tailscale/tailscale:latest /usr/local/bin/tailscaled /usr/local/bin/tailscaled
COPY --from=docker.io/tailscale/tailscale:latest /usr/local/bin/tailscale /usr/local/bin/tailscale

# Copy ProxyT binary from the official image on GHCR
# https://github.com/jaxxstorm/proxyt
COPY --from=ghcr.io/jaxxstorm/proxyt:latest /ko-app/proxyt /app/proxyt

# Patch /run.sh: change MTProxy port from 443 to 1234
RUN sed -i 's/-H 443/-H 1234/' /run.sh

# Create required directories
RUN mkdir -p /data /var/run/tailscale /var/cache/tailscale /var/lib/tailscale

# Copy startup script (orchestrates all three entrypoints)
COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh

CMD ["/bin/bash", "/app/start.sh"]
