#!/bin/sh
set -e

. /usr/local/lib/relay-lib.sh

strip_brackets() {
    _stripped=${1#[}
    printf '%s' "${_stripped%]}"
}

local_address() {
    _address=$(lan_addresses | head -n1)
    if [ -z "$_address" ]; then
        _address=$(global_addresses | head -n1)
    fi
    printf '%s' "$_address"
}

if [ -z "$DHCP_SERVER" ]; then
    echo "Error: [${log_tag}] DHCP_SERVER is not set" >&2
    exit 1
fi

if [ -z "$DHCP_LAN_IP" ]; then
    echo "Error: [${log_tag}] ${lan_ip_var} is not set" >&2
    exit 1
fi

DHCP_SERVER=$(strip_brackets "$DHCP_SERVER")

case "${dhcp_family}:${DHCP_SERVER}" in
    4:*[!0-9.]*|6:*[!0-9A-Fa-f:]*)
        echo "Error: [${log_tag}] DHCP_SERVER must be an IPv${dhcp_family} literal, got '${DHCP_SERVER}'" >&2
        exit 1
        ;;
esac

if [ -n "$DHCP_LOCAL_IP" ]; then
    DHCP_LOCAL_IP=$(strip_brackets "$DHCP_LOCAL_IP")
else
    echo "[${log_tag}] Waiting for a global IPv${dhcp_family} address on ${DHCP_IFACE}..."
    : >"$WAITING_MARKER"
    trap 'exit 0' TERM INT
    until DHCP_LOCAL_IP=$(local_address) && [ -n "$DHCP_LOCAL_IP" ]; do
        sleep 5 &
        wait $!
    done
    rm -f "$WAITING_MARKER"
fi

echo "[${log_tag}] Relaying DHCPv${dhcp_family} from ${DHCP_LOCAL_IP} (${DHCP_IFACE}) to ${DHCP_SERVER}"

if ! is_lan_address "$DHCP_LOCAL_IP"; then
    echo "Warning: [${log_tag}] relaying as ${DHCP_LOCAL_IP}, but ${lan_ip_var} is ${DHCP_LAN_IP}; Pi-hole drops every request" >&2
else
    echo "[${log_tag}] Pi-hole serves ${DHCP_LAN_IP}, which covers the relayed address"
fi

exec dnsmasq \
    --keep-in-foreground \
    --log-facility=- \
    --port=0 \
    --dhcp-relay="${DHCP_LOCAL_IP},${DHCP_SERVER}"
