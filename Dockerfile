FROM alpine:latest

# Copy ProxyT binary from the official image on GHCR
COPY --from=ghcr.io/jaxxstorm/proxyt:latest /ko-app/proxyt /app/proxyt

# Copy Tailscale CLI for querying Tailscale status via shared socket
COPY --from=docker.io/tailscale/tailscale:stable /usr/local/bin/tailscale /app/tailscale

# Copy start script
COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh

USER root

ENTRYPOINT ["/app/start.sh"]
