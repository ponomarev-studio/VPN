FROM alpine:latest

RUN apk add --no-cache \
    ca-certificates \
    tzdata

COPY --from=docker.io/tailscale/tailscale:stable \
    /usr/local/bin/tailscaled \
    /usr/local/bin/tailscaled

COPY --from=docker.io/tailscale/tailscale:stable \
    /usr/local/bin/tailscale \
    /usr/local/bin/tailscale

COPY --from=ghcr.io/jaxxstorm/proxyt:latest \
    /ko-app/proxyt \
    /usr/local/bin/proxyt

RUN mkdir -p \
    /var/run/tailscale \
    /var/cache/tailscale \
    /data/tailscale

COPY start.sh /app/start.sh

RUN chmod +x /app/start.sh

USER root

ENTRYPOINT ["/app/start.sh"]
