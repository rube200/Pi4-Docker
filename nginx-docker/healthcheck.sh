#!/bin/sh

readonly DAYS_UNTIL_EXPIRY=7
readonly SECONDS_UNTIL_EXPIRY=$((DAYS_UNTIL_EXPIRY * 86400))
readonly NGINX_CERT="/etc/nginx/ssl/fullchain.pem"

http_probe() {
    wget --quiet --tries=1 --spider "http://$1/healthz" && return 0
    echo "Error: [nginx-healthcheck] no HTTP answer from $1" >&2
    return 1
}

tls_probe() {
    openssl s_client -connect "$1" -servername "$HOST_SERVER_HOSTNAME" </dev/null >/dev/null 2>&1 && return 0
    echo "Error: [nginx-healthcheck] no TLS answer from $1" >&2
    return 1
}

quic_probe() {
    openssl s_client -quic -alpn h3 -connect "$1" -servername "$HOST_SERVER_HOSTNAME" </dev/null >/dev/null 2>&1 && return 0
    echo "Error: [nginx-healthcheck] no QUIC answer from $1" >&2
    return 1
}

http_probe "127.0.0.1" || exit 1
http_probe "[::1]" || exit 1

subject=$(openssl x509 -in "$NGINX_CERT" -noout -subject 2>/dev/null | sed 's/^subject=//')
issuer=$(openssl x509 -in "$NGINX_CERT" -noout -issuer 2>/dev/null | sed 's/^issuer=//')
if [ -z "$subject" ]; then
    echo "Error: [nginx-healthcheck] cannot read ${NGINX_CERT}" >&2
    exit 1
fi
if [ "$subject" = "$issuer" ]; then
    echo "Error: [nginx-healthcheck] serving a self-signed placeholder certificate" >&2
    exit 1
fi

if ! openssl x509 -in "$NGINX_CERT" -noout -checkend "$SECONDS_UNTIL_EXPIRY" >/dev/null; then
    echo "Error: [nginx-healthcheck] certificate expires within ${DAYS_UNTIL_EXPIRY} days" >&2
    exit 1
fi

tls_probe "127.0.0.1:443" || exit 1
tls_probe "[::1]:443" || exit 1
tls_probe "127.0.0.1:853" || exit 1
tls_probe "[::1]:853" || exit 1
tls_probe "127.0.0.1:8443" || exit 1
tls_probe "[::1]:8443" || exit 1
quic_probe "127.0.0.1:443" || exit 1
quic_probe "[::1]:443" || exit 1
quic_probe "127.0.0.1:8443" || exit 1
quic_probe "[::1]:8443" || exit 1
