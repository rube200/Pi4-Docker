#!/bin/sh

WG_DIR="/etc/wireguard"

for _f in "$WG_DIR"/wg*.conf; do
    [ -f "$_f" ] || continue
    _n=$(basename "$_f" .conf)
    if wg show "$_n" >/dev/null 2>&1; then
        exit 0
    fi
done

exit 1
