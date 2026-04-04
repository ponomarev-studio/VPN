# Build MTProxy binary from source (native Alpine build)
# https://github.com/TelegramMessenger/MTProxy
FROM alpine:latest AS mtproxy
RUN apk add --no-cache git make gcc musl-dev linux-headers openssl-dev zlib-dev coreutils
RUN git clone https://github.com/TelegramMessenger/MTProxy.git /src
WORKDIR /src

# musl compatibility: provide glibc-only drand48_r reentrant functions and struct
RUN printf '%s\n' \
  '#ifndef MUSL_COMPAT_H' \
  '#define MUSL_COMPAT_H' \
  '#ifndef __GLIBC__' \
  '#include <stdlib.h>' \
  'struct drand48_data {' \
  '  unsigned short __x[3];' \
  '  unsigned short __old_x[3];' \
  '  unsigned short __c;' \
  '  unsigned short __init;' \
  '  unsigned long long __a;' \
  '};' \
  'static inline int srand48_r(long s, struct drand48_data *b) { srand48(s); return 0; }' \
  'static inline int lrand48_r(struct drand48_data *b, long *r) { *r = lrand48(); return 0; }' \
  'static inline int drand48_r(struct drand48_data *b, double *r) { *r = drand48(); return 0; }' \
  '#endif' \
  '#endif' > common/musl-compat.h

RUN CC="gcc -include /src/common/musl-compat.h -Wno-incompatible-pointer-types" \
    make -j"$(nproc 2>/dev/null || echo 4)"

# Base image: Tailscale (Alpine-based, includes iptables and iproute2)
# Entrypoint: /usr/local/bin/containerboot
# https://hub.docker.com/r/tailscale/tailscale
FROM tailscale/tailscale:latest

# Runtime dependencies for MTProxy entrypoint (/run.sh)
RUN apk add --no-cache bash curl grep jq

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
