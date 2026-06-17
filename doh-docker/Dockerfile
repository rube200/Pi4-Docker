FROM alpine:3.24.1

ENV DOH_PROXY_VERSION=0.9.16

RUN apk upgrade --no-cache \
    && apk add --no-cache bzip2 curl tar

COPY docker-entrypoint.sh /usr/local/bin/
COPY healthcheck.sh /usr/local/bin/

RUN chmod +x /usr/local/bin/docker-entrypoint.sh /usr/local/bin/healthcheck.sh

EXPOSE 3000

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]