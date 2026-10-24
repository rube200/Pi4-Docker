FROM alpine:3.24.3

# unbound from Alpine edge: 3.24 ships 1.25.2, which lacks the 1.26.1/1.26.2 DNSSEC and
# parsing fixes (CVE-2026-81634, -85501, -96405) that malicious upstream replies can trigger.
# Drop the edge repo and @edge once the base image is Alpine 3.25.
RUN apk upgrade --no-cache \
    && echo "@edge https://dl-cdn.alpinelinux.org/alpine/edge/main" >> /etc/apk/repositories \
    && apk add --no-cache bind-tools unbound@edge \
    && mkdir -p /var/lib/unbound \
    && chown -R unbound:unbound /var/lib/unbound /etc/unbound

COPY --chmod=755 docker-entrypoint.sh /usr/local/bin/
COPY --chmod=644 pi-hole.conf /etc/unbound/unbound.conf.d/pi-hole.conf

EXPOSE 5335/udp
EXPOSE 5335/tcp

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["unbound", "-d"]
