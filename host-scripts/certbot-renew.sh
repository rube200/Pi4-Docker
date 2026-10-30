#!/bin/sh
set -e

readonly NGINX_CONTAINER="nginx"
readonly NGINX_SSL_DIR="/etc/nginx/ssl"

env_value() {
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$2" | tail -n1 | tr -d "\"'\r"
}

env_file="$(dirname "$(dirname "$(readlink -f "$0")")")/.env"
if [ -r "$env_file" ]; then
    [ -n "$HOST_SERVER_HOSTNAME" ] || HOST_SERVER_HOSTNAME=$(env_value HOST_SERVER_HOSTNAME "$env_file")
fi

if [ -z "$HOST_SERVER_HOSTNAME" ]; then
    echo "Error: [certbot-renew] HOST_SERVER_HOSTNAME is not set" >&2
    exit 1
fi

hostname_lower=$(printf '%s' "$HOST_SERVER_HOSTNAME" | tr '[:upper:]' '[:lower:]')
le_cert_dir="/etc/letsencrypt/live/${hostname_lower}"

if [ -n "$RENEWED_LINEAGE" ] && [ "$RENEWED_LINEAGE" != "$le_cert_dir" ]; then
    echo "[certbot-renew] Renewed ${RENEWED_LINEAGE} is not ${le_cert_dir}, nothing to deploy"
    exit 0
fi

if [ ! -f "${le_cert_dir}/fullchain.pem" ] || [ ! -f "${le_cert_dir}/privkey.pem" ]; then
    echo "Note: [certbot-renew] no certificate at ${le_cert_dir}, nothing to renew" >&2
    exit 0
fi

if [ -z "$RENEWED_LINEAGE" ]; then
    if ! command -v certbot >/dev/null 2>&1; then
        echo "Warning: [certbot-renew] certbot is not installed on the host, so nothing renews the certificate" >&2
        exit 0
    fi

    echo "[certbot-renew] Checking Let's Encrypt certificates..."
    if ! certbot renew; then
        echo "Warning: [certbot-renew] certificate renewal failed" >&2
        echo "  Existing certificates are untouched; the next run retries" >&2
    fi
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "Note: [certbot-renew] docker is not installed; nginx copies the certificate when it starts" >&2
    exit 0
fi

if [ "$(docker inspect -f '{{.State.Running}}' "$NGINX_CONTAINER" 2>/dev/null)" != "true" ]; then
    echo "[certbot-renew] Container ${NGINX_CONTAINER} is not running; its entrypoint copies the certificate at next start"
    exit 0
fi

host_fingerprint=$(openssl x509 -in "${le_cert_dir}/fullchain.pem" \
    -noout -fingerprint -sha256 2>/dev/null || true)
container_fingerprint=$(docker exec "$NGINX_CONTAINER" openssl x509 \
    -in "${NGINX_SSL_DIR}/fullchain.pem" -noout -fingerprint -sha256 2>/dev/null || true)

if [ -n "$host_fingerprint" ] && [ "$host_fingerprint" = "$container_fingerprint" ]; then
    echo "[certbot-renew] Container is already serving the current certificate"
    exit 0
fi

echo "[certbot-renew] Copying certificates into ${NGINX_CONTAINER}..."
if ! docker exec "$NGINX_CONTAINER" sh -c "
    cp '${le_cert_dir}/fullchain.pem' '${NGINX_SSL_DIR}/fullchain.pem' &&
    cp '${le_cert_dir}/privkey.pem' '${NGINX_SSL_DIR}/privkey.pem' &&
    chmod 644 '${NGINX_SSL_DIR}/fullchain.pem' &&
    chmod 600 '${NGINX_SSL_DIR}/privkey.pem'
"; then
    echo "Error: [certbot-renew] failed to copy certificates into ${NGINX_CONTAINER}" >&2
    exit 1
fi

if ! docker exec "$NGINX_CONTAINER" nginx -t; then
    echo "Error: [certbot-renew] nginx rejected the new certificate, not reloading" >&2
    echo "  The running server keeps serving the previously loaded one" >&2
    exit 1
fi

if ! docker exec "$NGINX_CONTAINER" nginx -s reload; then
    echo "Error: [certbot-renew] nginx reload failed" >&2
    exit 1
fi

echo "[certbot-renew] Certificate deployed and nginx reloaded"
