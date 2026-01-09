FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y bind9-dnsutils unbound-anchor unbound && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /var/lib/unbound && \
    chown -R unbound:unbound /var/lib/unbound /etc/unbound

COPY docker-entrypoint.sh /usr/local/bin/
COPY pi-hole.conf /etc/unbound/unbound.conf.d/pi-hole.conf

RUN chmod +x /usr/local/bin/docker-entrypoint.sh && \
    chmod 644 /etc/unbound/unbound.conf.d/pi-hole.conf

EXPOSE 5335/udp
EXPOSE 5335/tcp

HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 CMD dig +ad +short dnssec.works @127.0.0.1 -p 5335 || exit 1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["unbound", "-d"]
