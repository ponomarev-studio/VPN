# Build MTProxy binary from source (native Alpine build)
# https://github.com/TelegramMessenger/MTProxy
FROM alpine:latest AS mtproxy
RUN apk add --no-cache git make gcc musl-dev linux-headers openssl-dev zlib-dev
RUN git clone https://github.com/TelegramMessenger/MTProxy.git /src
WORKDIR /src
RUN make -j$(nproc)

# Base image: Tailscale (Alpine-based, includes iptables and iproute2)
# Entrypoint: /usr/local/bin/containerboot
# https://hub.docker.com/r/tailscale/tailscale
FROM tailscale/tailscale:latest

# Runtime dependencies for MTProxy entrypoint (/run.sh)
RUN apk add --no-cache bash curl grep

# Copy MTProxy binary (built natively for Alpine)
COPY --from=mtproxy /src/objs/bin/mtproto-proxy /bin/mtproto-proxy

# Copy original MTProxy entrypoint script from the official image
COPY --from=telegrammessenger/proxy:latest /run.sh /run.sh

# Copy ProxyT binary from the official image on GHCR
COPY --from=ghcr.io/jaxxstorm/proxyt:latest /ko-app/proxyt /app/proxyt

# Create persistent data directory
RUN mkdir -p /data

# Copy startup script (orchestrates all three entrypoints)
COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh

CMD ["/bin/bash", "/app/start.sh"]
