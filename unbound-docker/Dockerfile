FROM alpine:3.24.1

RUN apk upgrade --no-cache \
    && apk add --no-cache bind-tools unbound \
    && mkdir -p /var/lib/unbound \
    && chown -R unbound:unbound /var/lib/unbound /etc/unbound

COPY --chmod=755 docker-entrypoint.sh /usr/local/bin/
COPY --chmod=644 pi-hole.conf /etc/unbound/unbound.conf.d/pi-hole.conf

EXPOSE 5335/udp
EXPOSE 5335/tcp

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["unbound", "-d"]
