FROM alpine:3.23.4

RUN apk add --no-cache bind-tools unbound

RUN mkdir -p /var/lib/unbound && \
    chown -R unbound:unbound /var/lib/unbound /etc/unbound

COPY docker-entrypoint.sh /usr/local/bin/
COPY pi-hole.conf /etc/unbound/unbound.conf.d/pi-hole.conf

RUN chmod +x /usr/local/bin/docker-entrypoint.sh && \
    chmod 644 /etc/unbound/unbound.conf.d/pi-hole.conf

EXPOSE 5335/udp
EXPOSE 5335/tcp

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["unbound", "-d"]
