FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y unbound && \
    apt-get clean

COPY pi-hole.conf /etc/unbound/unbound.conf.d/pi-hole.conf

EXPOSE 5335/udp
EXPOSE 5335/tcp

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 CMD dig +ad dnssec.works @127.0.0.1 -p 5335 || exit 1

CMD ["unbound", "-d"]
