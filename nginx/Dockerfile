FROM nginx:alpine-slim

RUN apk add --no-cache certbot-nginx

COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

RUN rm -rf /usr/share/nginx/html/*

COPY nginx.conf /etc/nginx/nginx.conf
COPY conf.d/ /etc/nginx/conf.d/
COPY common.d/ /etc/nginx/common.d/
COPY stream-conf.d/ /etc/nginx/stream.d/
COPY templates/ /etc/nginx/templates/

COPY html/ /usr/share/nginx/html/

RUN mkdir -p /etc/nginx/ssl /var/www/certbot /var/cache/nginx/proxy /docker-entrypoint.d

COPY docker-entrypoint.sh /docker-entrypoint.d/10-cert-renewal.sh
RUN chmod +x /docker-entrypoint.d/10-cert-renewal.sh

EXPOSE 80 440 443 853

CMD ["nginx", "-g", "daemon off;"]