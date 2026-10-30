#!/bin/sh

dns_probe() {
    dig +short localhost @"$1" -p 5335 | grep -qE '^[0-9a-f.:]+$' && return 0
    echo "Error: [unbound-healthcheck] no answer from $1" >&2
    return 1
}

dns_probe 127.0.0.1 || exit 1
dns_probe ::1 || exit 1
