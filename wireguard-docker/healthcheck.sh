#!/bin/sh

readonly WG_CONFIG_DIR="/etc/wireguard"

has_wg_conf() {
    for _path in "$WG_CONFIG_DIR"/wg*.conf; do
        [ -f "$_path" ] && return 0
    done
    return 1
}

if ! has_wg_conf; then
    echo "Error: [wg-healthcheck] no wg*.conf in ${WG_CONFIG_DIR}" >&2
    exit 1
fi

for config_path in "$WG_CONFIG_DIR"/wg*.conf; do
    [ -f "$config_path" ] || continue
    interface_name=$(basename "$config_path" .conf)

    if ! wg show "$interface_name" >/dev/null 2>&1; then
        echo "Error: [wg-healthcheck] ${interface_name} is configured but not up" >&2
        exit 1
    fi

    if ! ip -4 -o addr show dev "$interface_name" scope global | grep -q .; then
        echo "Error: [wg-healthcheck] ${interface_name} has no IPv4 address" >&2
        exit 1
    fi

    if ! ip -6 -o addr show dev "$interface_name" scope global | grep -q .; then
        echo "Error: [wg-healthcheck] ${interface_name} has no IPv6 address" >&2
        exit 1
    fi
done
