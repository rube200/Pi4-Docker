#!/bin/sh
set -e

readonly DNS_RESOLVER="1.1.1.2"
readonly HOSTINGER_API_BASE="https://developers.hostinger.com"
readonly IPV4_REGEX='^([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$'
readonly IPV6_REGEX='^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$'
readonly IPV6_WAIT_SECONDS=60
readonly NL='
'

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

fetch_public_ip() {
    _family=$1
    _needed=$2
    shift 2
    _answers=
    for _endpoint in "$@"; do
        _body=$(curl_direct "$_family" "$_endpoint" -sf --max-time 5) || continue
        _body=$(printf '%s' "$_body" | tr -d '[:space:]')
        [ -n "$_body" ] || continue
        _answers="${_answers}${_body}${NL}"
        if [ "$(printf '%s' "$_answers" | grep -cxF "$_body")" -ge "$_needed" ]; then
            printf '%s' "$_body"
            return 0
        fi
    done
    return 1
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

record_content() {
    printf '%s\n' "$records_list" \
        | grep -F "\"type\":\"$1\"" \
        | grep -F "\"name\":\"$2\"" \
        | grep -o '"content":"[^"]*"' \
        | sed -n '1s/"content":"\([^"]*\)"/\1/p'
}

has_global_ip6() {
    ip -6 -o addr show scope global \
        | grep -v ' tentative' \
        | grep -q ' inet6 [23]'
}

stable_ip6() {
    _iface=$(ip -6 -o addr show to "$1" | awk '{print $2; exit}')
    ip -6 -o addr show dev "$_iface" scope global \
        | grep -v ' temporary' \
        | grep -v ' deprecated' \
        | grep ' inet6 [23]' \
        | awk '{print $4}' | cut -d/ -f1 | head -n1
}

lower() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

zone_is_current() {
    _want=$(lower "$2")
    for _name in "@" "*"; do
        _have=$(lower "$(record_content "$1" "$_name")")
        [ "$_have" = "$_want" ] || return 1
    done
    return 0
}

report_change() {
    if [ -z "$2" ]; then
        echo "[ddns] Creating $1 record: $3"
    elif [ "$(lower "$2")" = "$(lower "$3")" ]; then
        echo "[ddns] Restoring $1 records: $3"
    else
        echo "[ddns] Updating $1 record: $2 -> $3"
    fi
}

a_is_current() {
    zone_is_current "A" "$public_ip"
}

aaaa_is_current() {
    zone_is_current "AAAA" "$public_ip6"
}

zone_entry() {
    printf '{"name":"%s","records":[{"content":"%s"}],"ttl":3600,"type":"%s"}' \
        "$1" "$2" "$3"
}

env_file="$(dirname "$(dirname "$(readlink -f "$0")")")/.env"
if [ -r "$env_file" ]; then
    [ -n "$DNS_API" ] || DNS_API=$(env_value DNS_API "$env_file")
    [ -n "$HOST_SERVER_HOSTNAME" ] || HOST_SERVER_HOSTNAME=$(env_value HOST_SERVER_HOSTNAME "$env_file")
fi

if [ -z "$DNS_API" ]; then
    echo "Note: [ddns] DNS_API is not set, skipping Hostinger DNS record update" >&2
    exit 0
fi

if [ -z "$HOST_SERVER_HOSTNAME" ]; then
    echo "Error: [ddns] HOST_SERVER_HOSTNAME is not set" >&2
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "Error: [ddns] curl is not installed" >&2
    exit 1
fi

if ! command -v dig >/dev/null 2>&1; then
    echo "Warning: [ddns] dig is not installed; using the system resolver, which may not be up yet at boot" >&2
fi

hostname_lower=$(lower "$HOST_SERVER_HOSTNAME")

echo "[ddns] Getting public IPv4..."
public_ip=$(fetch_public_ip 4 2 \
    https://api.ipify.org \
    https://ifconfig.me \
    https://icanhazip.com \
    https://checkip.amazonaws.com) || true

if ! printf '%s' "$public_ip" | grep -qE "$IPV4_REGEX"; then
    echo "Error: [ddns] failed to get a public IPv4 that two services agree on" >&2
    exit 1
fi

if ! has_global_ip6; then
    echo "[ddns] Waiting up to ${IPV6_WAIT_SECONDS}s for a global IPv6 address..."
    waited=0
    while ! has_global_ip6 && [ "$waited" -lt "$IPV6_WAIT_SECONDS" ]; do
        sleep 5
        waited=$((waited + 5))
    done
fi

echo "[ddns] Getting public IPv6..."
public_ip6=$(fetch_public_ip 6 1 \
    https://api6.ipify.org \
    https://ipv6.icanhazip.com \
    https://v6.ident.me \
    https://ifconfig.me) || true

if [ -n "$public_ip6" ] && ip -6 -o addr show to "$public_ip6" 2>/dev/null | grep -q ' temporary'; then
    echo "[ddns] ${public_ip6} is a temporary address, using the stable one"
    public_ip6=$(stable_ip6 "$public_ip6")
fi

if ! printf '%s' "$public_ip6" | grep -qE "$IPV6_REGEX" || ! printf '%s' "$public_ip6" | grep -qE '^[23]'; then
    echo "Error: [ddns] failed to get a global public IPv6" >&2
    exit 1
fi

if [ -z "$(ip -6 -o addr show to "$public_ip6" 2>/dev/null)" ]; then
    echo "Error: [ddns] ${public_ip6} is not an address of this host, refusing to publish it" >&2
    exit 1
fi

echo "[ddns] Fetching DNS records..."
hostinger_zone_api

if [ "$http_code" != "200" ]; then
    echo "Error: [ddns] failed to fetch DNS records (HTTP ${http_code})" >&2
    echo "  Response: ${response_body}" >&2
    exit 1
fi

records_list=$(printf '%s' "$response_body" | sed 's/{"name":/\n{"name":/g')

current_ip=$(record_content "A" "@")
printf '%s' "$current_ip" | grep -qE "$IPV4_REGEX" || current_ip=""

current_ip6=$(record_content "AAAA" "@")
printf '%s' "$current_ip6" | grep -qE "$IPV6_REGEX" || current_ip6=""

if a_is_current && aaaa_is_current; then
    echo "[ddns] A (${current_ip}) and AAAA (${current_ip6}) records are up to date"
    exit 0
fi

a_is_current || report_change "A" "$current_ip" "$public_ip"
aaaa_is_current || report_change "AAAA" "$current_ip6" "$public_ip6"

zone_entries="$(zone_entry '@' "$public_ip" 'A'),$(zone_entry '*' "$public_ip" 'A'),$(zone_entry '@' "$public_ip6" 'AAAA'),$(zone_entry '*' "$public_ip6" 'AAAA')"
json_payload="{\"overwrite\":true,\"zone\":[${zone_entries}]}"

hostinger_zone_api -X PUT \
    -H "Content-Type: application/json" \
    -d "$json_payload"

if [ "$http_code" != "200" ] && [ "$http_code" != "201" ]; then
    echo "Error: [ddns] failed to write DNS records (HTTP ${http_code})" >&2
    echo "  Response: ${response_body}" >&2
    exit 1
fi

echo "[ddns] A record set to ${public_ip}, AAAA record set to ${public_ip6}"
