FROM nginx:1.31.8-alpine-slim

RUN apk upgrade --no-cache \
    && apk add --no-cache openssl \
    && rm -rf /usr/share/nginx/html/* \
    && rm -f /etc/nginx/conf.d/default.conf \
    && mkdir -p /etc/nginx/ssl

COPY conf/ /etc/nginx/
COPY html/ /usr/share/nginx/html/
COPY --chmod=755 docker-entrypoint.sh /docker-entrypoint.d/10-certificates.sh
COPY --chmod=755 healthcheck.sh /usr/local/bin/

EXPOSE 80/tcp 443/tcp 443/udp 853/tcp 8443/tcp 8443/udp

CMD ["nginx", "-g", "daemon off;"]
