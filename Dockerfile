FROM alpine:latest
RUN apk update && apk add ca-certificates iptables iptables-legacy ip6tables && rm -rf /var/cache/apk/* && ln -sf /sbin/iptables-legacy /sbin/iptables && ln -sf /sbin/ip6tables-legacy /sbin/ip6tables

COPY --from=docker.io/tailscale/tailscale:latest /usr/local/bin/tailscaled /usr/local/bin/tailscaled
COPY --from=docker.io/tailscale/tailscale:latest /usr/local/bin/tailscale /usr/local/bin/tailscale

RUN mkdir -p /var/run/tailscale /var/cache/tailscale /var/lib/tailscale /data/tailscale

COPY --from=ghcr.io/jaxxstorm/proxyt:latest /ko-app/proxyt /usr/local/bin/proxyt

COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh

USER root

ENTRYPOINT ["/app/start.sh"]
