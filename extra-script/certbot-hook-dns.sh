#!/bin/sh
set -e

HOSTINGER_API_BASE="https://developers.hostinger.com"
ACME_CHALLENGE_NAME="_acme-challenge"
MODE="${1:-}"

if [ -z "${DNS_API:-}" ]; then
    echo "Error: DNS_API environment variable required" >&2
    exit 1
fi

if [ -z "${CERTBOT_DOMAIN:-}" ] || [ -z "${CERTBOT_VALIDATION:-}" ]; then
    echo "Error: CERTBOT_DOMAIN and CERTBOT_VALIDATION must be set" >&2
    exit 1
fi

domain="$CERTBOT_DOMAIN"
validation="$CERTBOT_VALIDATION"

if echo "$domain" | grep -q '^\*\.'; then
    domain=$(echo "$domain" | sed 's/^\*\.//')
fi

validation_esc=$(printf '%s' "$validation" | sed 's/\\/\\\\/g; s/"/\\"/g')

public_txt_visible() {
    _fqdn="${ACME_CHALLENGE_NAME}.${domain}"
    _g=""
    _g=$(curl -sS --max-time 8 \
        "https://dns.google/resolve?name=${_fqdn}&type=TXT" 2>/dev/null) || true
    if echo "$_g" | grep -qF "$validation"; then
        return 0
    fi
    _c=""
    _c=$(curl -sS --max-time 8 \
        -H "Accept: application/dns-json" \
        "https://cloudflare-dns.com/dns-query?name=${_fqdn}&type=TXT" 2>/dev/null) || true
    if echo "$_c" | grep -qF "$validation"; then
        return 0
    fi
    return 1
}

wait_for_public_txt() {
    _fqdn="${ACME_CHALLENGE_NAME}.${domain}"
    echo "Checking public DNS for TXT at ${_fqdn} (after 5s, then +10s, then +30s)..."
    sleep 5
    if public_txt_visible; then
        echo "TXT visible after first wait (5s)."
        return 0
    fi
    echo "TXT not visible yet; waiting 10s..."
    sleep 10
    if public_txt_visible; then
        echo "TXT visible after second wait (15s total)."
        return 0
    fi
    echo "TXT not visible yet; waiting 30s..."
    sleep 30
    if public_txt_visible; then
        echo "TXT visible after third wait (45s total)."
        return 0
    fi
    echo "Error: TXT for ${_fqdn} not visible via public DNS after 5s, 10s, and 30s waits." >&2
    echo "Check nameservers (Hostinger), propagation, and that the API zone matches the live DNS." >&2
    exit 1
}

case "$MODE" in
    auth)
        echo "Creating TXT record for ${ACME_CHALLENGE_NAME}.${domain}..."
        json_payload="{\"overwrite\":false,\"zone\":[{\"name\":\"${ACME_CHALLENGE_NAME}\",\"records\":[{\"content\":\"${validation_esc}\"}],\"ttl\":3600,\"type\":\"TXT\"}]}"
        response=$(curl -s -w "\n%{http_code}" \
            -X PUT \
            -H "Authorization: Bearer ${DNS_API}" \
            -H "Content-Type: application/json" \
            -H "Accept: application/json" \
            -d "$json_payload" \
            "${HOSTINGER_API_BASE}/api/dns/v1/zones/${domain}" 2>&1) || true

        http_code=$(echo "$response" | tail -n1)
        if [ "$http_code" != "200" ] && [ "$http_code" != "201" ]; then
            echo "Error: Failed to create TXT record. HTTP $http_code" >&2
            echo "$response" | sed '$d' >&2
            exit 1
        fi

        echo "TXT record created successfully"
        wait_for_public_txt
        ;;
    cleanup)
        echo "Deleting TXT record for ${ACME_CHALLENGE_NAME}.${domain}..."
        json_payload="{\"filters\":[{\"name\":\"${ACME_CHALLENGE_NAME}\",\"type\":\"TXT\"}]}"
        response=$(curl -s -w "\n%{http_code}" \
            -X DELETE \
            -H "Authorization: Bearer ${DNS_API}" \
            -H "Content-Type: application/json" \
            -H "Accept: application/json" \
            -d "$json_payload" \
            "${HOSTINGER_API_BASE}/api/dns/v1/zones/${domain}" 2>&1) || true

        http_code=$(echo "$response" | tail -n1)
        if [ "$http_code" = "200" ]; then
            echo "TXT record deleted successfully"
        else
            echo "Warning: cleanup HTTP $http_code (may be harmless if nothing to remove)" >&2
            echo "$response" | sed '$d' >&2
        fi
        ;;
    *)
        echo "Usage: $0 auth|cleanup  (set manual_auth_hook / manual_cleanup_hook in renewal.conf)" >&2
        exit 1
        ;;
esac
