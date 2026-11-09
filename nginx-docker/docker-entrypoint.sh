#!/bin/sh
set -e

readonly NGINX_SSL_DIR="/etc/nginx/ssl"
readonly QUIC_HOST_KEY="${NGINX_SSL_DIR}/quic_host.key"

has_current_certificate() {
    [ -f "${NGINX_SSL_DIR}/fullchain.pem" ] && [ -f "${NGINX_SSL_DIR}/privkey.pem" ] \
        && openssl x509 -in "${NGINX_SSL_DIR}/fullchain.pem" -noout -checkend 0 >/dev/null 2>&1
}

if [ -z "$HOST_SERVER_HOSTNAME" ]; then
    echo "Error: [nginx] HOST_SERVER_HOSTNAME is not set" >&2
    exit 1
fi

hostname_lower=$(printf '%s' "$HOST_SERVER_HOSTNAME" | tr '[:upper:]' '[:lower:]')
le_cert_dir="/etc/letsencrypt/live/${hostname_lower}"

echo "[nginx] Checking Let's Encrypt certificates..."
if [ -f "${le_cert_dir}/fullchain.pem" ] && [ -f "${le_cert_dir}/privkey.pem" ]; then
    echo "[nginx] Copying certificates to nginx ssl directory..."
    cp "${le_cert_dir}/fullchain.pem" "${NGINX_SSL_DIR}/fullchain.pem"
    cp "${le_cert_dir}/privkey.pem" "${NGINX_SSL_DIR}/privkey.pem"
    chmod 644 "${NGINX_SSL_DIR}/fullchain.pem"
    chmod 600 "${NGINX_SSL_DIR}/privkey.pem"
    echo "[nginx] Certificates ready"
else
    echo "Note: [nginx] no certificate at ${le_cert_dir}" >&2
fi

if ! has_current_certificate; then
    echo "Warning: [nginx] generating a self-signed placeholder so nginx can start" >&2
    if ! openssl req -x509 -newkey rsa:2048 -nodes -days 14 \
        -subj "/CN=${hostname_lower}" \
        -addext "subjectAltName=DNS:${hostname_lower},DNS:*.${hostname_lower}" \
        -keyout "${NGINX_SSL_DIR}/privkey.pem" \
        -out "${NGINX_SSL_DIR}/fullchain.pem" >/dev/null 2>&1; then
        echo "Error: [nginx] placeholder generation failed" >&2
        exit 1
    fi
    chmod 644 "${NGINX_SSL_DIR}/fullchain.pem"
    chmod 600 "${NGINX_SSL_DIR}/privkey.pem"
fi

if [ ! -f "$QUIC_HOST_KEY" ]; then
    echo "[nginx] Generating QUIC host key..."
    if ! openssl rand -out "$QUIC_HOST_KEY" 32; then
        echo "Error: [nginx] QUIC host key generation failed" >&2
        exit 1
    fi
    chmod 600 "$QUIC_HOST_KEY"
fi
