#!/bin/bash
set -e

readonly PIHOLE_CERT_DIR="/etc/pihole"
readonly PIHOLE_CERT="${PIHOLE_CERT_DIR}/tls.pem"
readonly DAYS_UNTIL_EXPIRY=7
readonly SECONDS_UNTIL_EXPIRY=$((DAYS_UNTIL_EXPIRY * 86400))

if [[ ! -f "$PIHOLE_CERT" ]]; then
    echo "Pi-hole TLS cert not found, skipping" >&2
    exit 0
fi

if openssl x509 -in "$PIHOLE_CERT" -checkend "$SECONDS_UNTIL_EXPIRY" -noout 2>/dev/null; then
    exit 0
fi

echo "Pi-hole TLS cert expires within ${DAYS_UNTIL_EXPIRY} days, removing for regeneration..."
rm -f "${PIHOLE_CERT_DIR}/tls.pem" "${PIHOLE_CERT_DIR}/tls_ca.crt" "${PIHOLE_CERT_DIR}/tls.crt"
echo "Pi-hole will generate a new cert on startup"
