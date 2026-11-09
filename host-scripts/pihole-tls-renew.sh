#!/bin/sh
set -e

readonly DAYS_UNTIL_EXPIRY=7
readonly SECONDS_UNTIL_EXPIRY=$((DAYS_UNTIL_EXPIRY * 86400))
readonly PIHOLE_CERT_DIR="/etc/pihole"
readonly PIHOLE_CERT="${PIHOLE_CERT_DIR}/tls.pem"
readonly PIHOLE_CONTAINER="pihole"

if [ ! -f "$PIHOLE_CERT" ]; then
    echo "Note: [pihole-tls] no certificate at ${PIHOLE_CERT}, nothing to renew" >&2
    exit 0
fi

if ! command -v openssl >/dev/null 2>&1; then
    echo "Warning: [pihole-tls] openssl is not installed on the host, so nothing renews the certificate" >&2
    exit 0
fi

if openssl x509 -in "$PIHOLE_CERT" -noout -checkend "$SECONDS_UNTIL_EXPIRY" >/dev/null 2>&1; then
    exit 0
fi

echo "[pihole-tls] Certificate expires within ${DAYS_UNTIL_EXPIRY} days, removing it..."
rm -f "$PIHOLE_CERT" "${PIHOLE_CERT_DIR}/tls_ca.crt" "${PIHOLE_CERT_DIR}/tls.crt"

if ! command -v docker >/dev/null 2>&1; then
    echo "Note: [pihole-tls] docker is not installed; Pi-hole generates a new certificate when it starts" >&2
    exit 0
fi

if [ "$(docker inspect -f '{{.State.Running}}' "$PIHOLE_CONTAINER" 2>/dev/null)" != "true" ]; then
    echo "[pihole-tls] Container ${PIHOLE_CONTAINER} is not running; it generates a new certificate at next start"
    exit 0
fi

echo "[pihole-tls] Restarting ${PIHOLE_CONTAINER} so it generates a new certificate..."
if ! docker restart "$PIHOLE_CONTAINER" >/dev/null; then
    echo "Error: [pihole-tls] failed to restart ${PIHOLE_CONTAINER}" >&2
    exit 1
fi

echo "[pihole-tls] ${PIHOLE_CONTAINER} restarted"
