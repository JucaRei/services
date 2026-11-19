# ==============================================================================
# Caddy Custom Build com Plugin CrowdSec Bouncer
# ==============================================================================
FROM caddy:builder-alpine AS builder

RUN xcaddy build \
    --with github.com/hslatman/caddy-crowdsec-bouncer

FROM caddy:alpine

COPY --from=builder /usr/bin/caddy /usr/bin/caddy

