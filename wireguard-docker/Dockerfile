FROM alpine:3.23

RUN apk add --no-cache wireguard-tools

COPY docker-entrypoint.sh /usr/local/bin/
COPY healthcheck.sh /usr/local/bin/
COPY create-client.sh /usr/local/bin/
COPY wg0.conf.template /usr/local/share/wireguard/wg0.conf.template
RUN chmod +x /usr/local/bin/docker-entrypoint.sh /usr/local/bin/healthcheck.sh /usr/local/bin/create-client.sh

EXPOSE 51820/udp

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
