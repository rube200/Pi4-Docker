#!/bin/sh

doh_probe() {
    curl -sf --max-time 3 \
        -H "Accept: application/dns-json" \
        "http://$1/${DOH_PATH}?name=dnssec.works&cd=1&do=1&edns_client_subnet" \
        -o /dev/null && return 0
    echo "Error: [doh-healthcheck] no answer from $1" >&2
    return 1
}

doh_probe "$DOH_LISTEN" || exit 1
doh_probe "$DOH_LISTEN6" || exit 1
