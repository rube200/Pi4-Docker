#!/bin/sh

doh_probe() {
    curl -sf --max-time 3 \
        -H "Accept: application/dns-json" \
        -H "X-Forwarded-For: $2" \
        "http://$1/${DOH_PATH}?name=dnssec.works&cd=1&do=1&edns_client_subnet" \
        -o /dev/null && return 0
    echo "Error: [doh-healthcheck] no answer from $1" >&2
    return 1
}

doh_probe "$DOH_LISTEN" "1.1.1.1" || exit 1
doh_probe "$DOH_LISTEN6" "2606:4700:4700::1111" || exit 1
