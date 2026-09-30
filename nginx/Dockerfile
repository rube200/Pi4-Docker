FROM nginx:1.31.6-alpine-slim

RUN apk upgrade --no-cache \
    && apk add --no-cache certbot-nginx \
    && rm -rf /usr/share/nginx/html/* \
    && mkdir -p /etc/nginx/ssl /var/www/certbot /var/cache/nginx/proxy

COPY nginx.conf /etc/nginx/nginx.conf
COPY conf.d/ /etc/nginx/conf.d/
COPY common.d/ /etc/nginx/common.d/
COPY stream-conf.d/ /etc/nginx/stream.d/
COPY templates/ /etc/nginx/templates/

COPY html/ /usr/share/nginx/html/

COPY --chmod=755 docker-entrypoint.sh /docker-entrypoint.d/10-cert-renewal.sh

EXPOSE 80 440 443 853

CMD ["nginx", "-g", "daemon off;"]