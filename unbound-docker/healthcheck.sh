#!/bin/sh

dns_probe() {
    dig +short localhost @"$1" -p 5335 | grep -qE '^[0-9a-f.:]+$' && return 0
    echo "Error: [unbound-healthcheck] no answer from $1" >&2
    return 1
}

quad9_probe() {
    for addr in 9.9.9.9 149.112.112.112 2620:fe::fe 2620:fe::9; do
        dig +short +time=1 +tries=1 +tls +tls-ca=/etc/ssl/certs/ca-certificates.crt \
            +tls-hostname=dns.quad9.net dns.quad9.net @"$addr" | grep -qE '^[0-9a-f.:]+$' && return 0
    done
    echo "Error: [unbound-healthcheck] Quad9 unreachable over DNS-over-TLS" >&2
    return 1
}

dns_probe 127.0.0.1 || exit 1
dns_probe ::1 || exit 1
quad9_probe || exit 1
