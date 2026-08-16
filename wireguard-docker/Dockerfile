FROM alpine:3.24.1

RUN apk upgrade --no-cache \
    && apk add --no-cache bind-tools ip6tables iptables wireguard-tools

COPY --chmod=755 \
    docker-entrypoint.sh \
    healthcheck.sh \
    create-client.sh \
    wg-container-firewall.sh \
    /usr/local/bin/

COPY wg0.conf.template /usr/local/share/wireguard/wg0.conf.template

EXPOSE 51820/udp

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
