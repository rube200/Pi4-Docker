#!/bin/sh
set -e

readonly ACME_CHALLENGE_NAME="_acme-challenge"
readonly DNS_RESOLVER="1.1.1.2"
readonly HOSTINGER_API_BASE="https://developers.hostinger.com"
readonly NL='
'
readonly PROPAGATION_WAITS="5 10 30"
readonly PUBLIC_RESOLVERS="https://dns.google/resolve https://cloudflare-dns.com/dns-query"

env_value() {
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$2" | tail -n1 | tr -d "\"'\r"
}

curl_direct() {
    _family=$1
    _url=$2
    shift 2
    _host=${_url#*://}
    _host=${_host%%/*}
    _host=${_host%%:*}
    if [ "$_family" = "6" ]; then
        _ip=$(dig +short "$_host" @"$DNS_RESOLVER" AAAA 2>/dev/null | grep -E '^[0-9a-fA-F:]+$' | head -n1)
        if [ -n "$_ip" ]; then
            _ip="[${_ip}]"
        fi
    else
        _ip=$(dig +short "$_host" @"$DNS_RESOLVER" A 2>/dev/null | grep -E '^[0-9.]+$' | head -n1)
    fi
    if [ -n "$_ip" ]; then
        curl "-${_family}" --resolve "${_host}:443:${_ip}" "$@" "$_url"
    else
        curl "-${_family}" "$@" "$_url"
    fi
}

hostinger_zone_api() {
    _response=$(printf 'Authorization: Bearer %s\n' "$DNS_API" \
        | curl_direct 4 "${HOSTINGER_API_BASE}/api/dns/v1/zones/${hostname_lower}" \
            -s -w "\n%{http_code}" \
            --max-time 30 \
            -H @- \
            -H "Accept: application/json" \
            "$@") || true
    http_code=${_response##*"$NL"}
    response_body=${_response%"$NL"*}
}

lower() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

public_txt_visible() {
    for _resolver in $PUBLIC_RESOLVERS; do
        _answer=$(curl_direct 4 "${_resolver}?name=${acme_fqdn}&type=TXT" \
            -sf --max-time 8 \
            -H "Accept: application/dns-json") || true
        if printf '%s' "$_answer" | grep -qF "$CERTBOT_VALIDATION"; then
            return 0
        fi
    done
    return 1
}

wait_for_public_txt() {
    echo "[certbot-dns] Checking public DNS for TXT at ${acme_fqdn}..."
    _elapsed=0
    for _wait in $PROPAGATION_WAITS; do
        sleep "$_wait"
        _elapsed=$((_elapsed + _wait))
        if public_txt_visible; then
            echo "[certbot-dns] TXT visible after ${_elapsed}s"
            return 0
        fi
    done
    echo "Error: [certbot-dns] TXT for ${acme_fqdn} not visible via public DNS after ${_elapsed}s" >&2
    exit 1
}

MODE=$1

case "$MODE" in
    auth|cleanup) ;;
    *)
        echo "Error: [certbot-dns] invalid usage" >&2
        echo "  Usage: $0 auth|cleanup" >&2
        exit 1
        ;;
esac

env_file="$(dirname "$(dirname "$(readlink -f "$0")")")/.env"
if [ -r "$env_file" ]; then
    [ -n "$DNS_API" ] || DNS_API=$(env_value DNS_API "$env_file")
    [ -n "$HOST_SERVER_HOSTNAME" ] || HOST_SERVER_HOSTNAME=$(env_value HOST_SERVER_HOSTNAME "$env_file")
fi

if [ -z "$DNS_API" ]; then
    echo "Error: [certbot-dns] DNS_API is not set" >&2
    exit 1
fi

if [ -z "$HOST_SERVER_HOSTNAME" ]; then
    echo "Error: [certbot-dns] HOST_SERVER_HOSTNAME is not set" >&2
    exit 1
fi

if [ -z "$CERTBOT_DOMAIN" ] || [ -z "$CERTBOT_VALIDATION" ]; then
    echo "Error: [certbot-dns] CERTBOT_DOMAIN or CERTBOT_VALIDATION is not set" >&2
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "Error: [certbot-dns] curl is not installed" >&2
    exit 1
fi

if ! command -v dig >/dev/null 2>&1; then
    echo "Warning: [certbot-dns] dig is not installed; using the system resolver, which may not be up yet at boot" >&2
fi

hostname_lower=$(lower "$HOST_SERVER_HOSTNAME")
domain=$(lower "${CERTBOT_DOMAIN#\*.}")
acme_fqdn="${ACME_CHALLENGE_NAME}.${domain}"

case "$domain" in
    "$hostname_lower")
        record_name="$ACME_CHALLENGE_NAME"
        ;;
    *."$hostname_lower")
        record_name="${ACME_CHALLENGE_NAME}.${domain%."$hostname_lower"}"
        ;;
    *)
        echo "Error: [certbot-dns] ${domain} is not in the ${hostname_lower} zone" >&2
        exit 1
        ;;
esac

validation_esc=$(printf '%s' "$CERTBOT_VALIDATION" | sed 's/\\/\\\\/g; s/"/\\"/g')

case "$MODE" in
    auth)
        echo "[certbot-dns] Creating TXT record for ${acme_fqdn}..."
        hostinger_zone_api -X PUT \
            -H "Content-Type: application/json" \
            -d "{\"overwrite\":false,\"zone\":[{\"name\":\"${record_name}\",\"records\":[{\"content\":\"${validation_esc}\"}],\"ttl\":3600,\"type\":\"TXT\"}]}"

        if [ "$http_code" != "200" ] && [ "$http_code" != "201" ]; then
            echo "Error: [certbot-dns] failed to create TXT record (HTTP ${http_code})" >&2
            echo "  Response: ${response_body}" >&2
            exit 1
        fi

        echo "[certbot-dns] TXT record created successfully"
        wait_for_public_txt
        ;;
    cleanup)
        echo "[certbot-dns] Deleting TXT record for ${acme_fqdn}..."
        hostinger_zone_api -X DELETE \
            -H "Content-Type: application/json" \
            -d "{\"filters\":[{\"name\":\"${record_name}\",\"type\":\"TXT\"}]}"

        if [ "$http_code" = "200" ]; then
            echo "[certbot-dns] TXT record deleted successfully"
        else
            echo "Warning: [certbot-dns] cleanup returned HTTP ${http_code} (may be harmless if nothing to remove)" >&2
            echo "  Response: ${response_body}" >&2
        fi
        ;;
esac
