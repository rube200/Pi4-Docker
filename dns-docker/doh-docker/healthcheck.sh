#!/bin/sh
DOH_PATH_PREFIX="${DOH_PATH_PREFIX:-query-dns}"

curl -f -s -m 3 \
  -H "Accept: application/dns-json" \
  -H "X-Forwarded-For: 1.1.1.1" \
  "http://127.0.0.1:3000/${DOH_PATH_PREFIX}?name=dnssec.works&cd=1&do=1&edns_client_subnet" \
  -o /dev/null || exit 1