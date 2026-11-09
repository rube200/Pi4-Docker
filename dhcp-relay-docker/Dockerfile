FROM alpine:3.24.4

RUN apk upgrade --no-cache \
    && apk add --no-cache dnsmasq iproute2 tzdata

COPY --chmod=644 relay-lib.sh /usr/local/lib/
COPY --chmod=755 docker-entrypoint.sh healthcheck.sh /usr/local/bin/

EXPOSE 67/udp 547/udp

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
