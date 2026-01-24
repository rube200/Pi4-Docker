#!/bin/sh
if [ -z "$WIREGUARD_INTERFACE" ]; then
    INTERFACE="${WIREGUARD_CONFIG%.conf}"
else
    INTERFACE="$WIREGUARD_INTERFACE"
fi
wg show "$INTERFACE" >/dev/null 2>&1