FROM alpine:3.24.4

ARG DOH_PROXY_VERSION=0.11.1
ARG DOH_PROXY_SHA256_AARCH64=579f63372b23e904761d3b12aeb5aa3031403dda1d03f95288b0ef5b21e8c36c
ARG DOH_PROXY_SHA256_X86_64=7ce97a4ed3d9deee9d2b1de71bb60013f46188f5d2a085fbf230bf4c8e3c8b25

RUN apk upgrade --no-cache \
    && apk add --no-cache curl tzdata

RUN --mount=type=bind,source=install-doh-proxy.sh,target=/install-doh-proxy.sh \
    sh /install-doh-proxy.sh

COPY --chmod=755 docker-entrypoint.sh healthcheck.sh /usr/local/bin/

EXPOSE 3000/tcp

USER nobody

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
