FROM alpine:3.24.2

ENV DOH_PROXY_VERSION=0.10.0

RUN apk upgrade --no-cache \
    && apk add --no-cache curl

RUN --mount=type=bind,source=install-doh-proxy.sh,target=/install-doh-proxy.sh \
    sh /install-doh-proxy.sh

COPY --chmod=755 docker-entrypoint.sh healthcheck.sh /usr/local/bin/

EXPOSE 3000

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]