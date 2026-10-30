FROM alpine:3.24.3

RUN apk upgrade --no-cache \
    && apk add --no-cache bind-tools iptables tzdata wireguard-tools

COPY --chmod=644 wg0.conf.template /usr/local/share/wireguard/wg0.conf.template
COPY --chmod=755 \
    create-client.sh \
    docker-entrypoint.sh \
    healthcheck.sh \
    wg-container-firewall.sh \
    /usr/local/bin/

EXPOSE 51820/udp

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
