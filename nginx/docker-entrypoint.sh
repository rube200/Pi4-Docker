#!/bin/sh
set -e

[ -z "$SERVER_HOSTNAME" ] && echo "Error: SERVER_HOSTNAME is not set and no config file found" && exit 1

SERVER_HOSTNAME_LOWER=$(echo "$SERVER_HOSTNAME" | tr '[:upper:]' '[:lower:]')
LE_CERT_DIR="/etc/letsencrypt/live/${SERVER_HOSTNAME_LOWER}"
NGINX_SSL_DIR="/etc/nginx/ssl"

echo "Checking Let's Encrypt certificates..."
if [ -f "${LE_CERT_DIR}/fullchain.pem" ] && [ -f "${LE_CERT_DIR}/privkey.pem" ]; then
    echo "Attempting certificate renewal..."
    RENEWAL_OUTPUT=$(certbot renew --quiet 2>&1)
    RENEWAL_EXIT_CODE=$?
    
    if [ $RENEWAL_EXIT_CODE -ne 0 ]; then
        echo "Certificate renewal failed with exit code: ${RENEWAL_EXIT_CODE}"
        [ -n "$RENEWAL_OUTPUT" ] && echo "Error output: ${RENEWAL_OUTPUT}"
        echo "Continuing with existing certificates..."
    else
        echo "Certificate renewal successful"
    fi
    
    echo "Copying certificates to nginx ssl directory..."
    cp "${LE_CERT_DIR}/fullchain.pem" "${NGINX_SSL_DIR}/fullchain.pem"
    cp "${LE_CERT_DIR}/privkey.pem" "${NGINX_SSL_DIR}/privkey.pem"
    chmod 644 "${NGINX_SSL_DIR}/fullchain.pem"
    chmod 600 "${NGINX_SSL_DIR}/privkey.pem"
    echo "Certificates ready"
else
    echo "Error: Let's Encrypt certificates not found"
    echo "Trying to continue without certificates"
fi