FROM alpine:3.24.3

ARG DOH_PROXY_VERSION=0.10.0
ARG DOH_PROXY_SHA256_AARCH64=f588e5bafcd4b36e490466bbbb693eae6e1d783c68dbb5314a1523bd1a27f114
ARG DOH_PROXY_SHA256_X86_64=98a8e2a3fa9ad4ffccded1ef6e1d0b2a6647755edea76ed3394cc7b27ea34829

RUN apk upgrade --no-cache \
    && apk add --no-cache curl tzdata

RUN --mount=type=bind,source=install-doh-proxy.sh,target=/install-doh-proxy.sh \
    sh /install-doh-proxy.sh

COPY --chmod=755 docker-entrypoint.sh healthcheck.sh /usr/local/bin/

EXPOSE 3000/tcp

USER nobody

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
