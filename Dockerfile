# Based on the official Telegram MTProxy image
# https://hub.docker.com/r/telegrammessenger/proxy
FROM telegrammessenger/proxy:latest

# Fix archived Debian Jessie repos and install packages for exit node
RUN echo "deb http://archive.debian.org/debian jessie main" > /etc/apt/sources.list && \
    apt-get -o Acquire::Check-Valid-Until=false update && \
    apt-get install -y --allow-unauthenticated --no-install-recommends iptables kmod && \
    rm -rf /var/lib/apt/lists/*

# Copy Tailscale binaries from the official image on Docker Hub
COPY --from=docker.io/tailscale/tailscale:latest /usr/local/bin/tailscaled /app/tailscaled
COPY --from=docker.io/tailscale/tailscale:latest /usr/local/bin/tailscale /app/tailscale

# Copy ProxyT binary from the official image on GHCR
COPY --from=ghcr.io/jaxxstorm/proxyt:latest /ko-app/proxyt /app/proxyt

# Create required directories
RUN mkdir -p /var/run/tailscale /var/cache/tailscale /var/lib/tailscale /data/tailscale

# Copy startup script
COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh

USER root

CMD ["/bin/bash", "/app/start.sh"]
