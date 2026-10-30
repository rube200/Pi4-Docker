#!/bin/sh

. /usr/local/lib/relay-lib.sh

stamped_address() {
    tr '\0' '\n' </proc/1/cmdline \
        | sed -n 's/^--dhcp-relay=//p' \
        | head -n1 \
        | cut -d, -f1
}

if [ -e "$WAITING_MARKER" ]; then
    echo "Error: [${log_tag}-healthcheck] no global IPv${dhcp_family} address on ${DHCP_IFACE} yet, not relaying" >&2
    exit 1
fi

if ! grep -qE "^ *[0-9]+: [0-9A-F]+:${dhcp_port_hex} " "$dhcp_proc"; then
    echo "Error: [${log_tag}-healthcheck] nothing is bound to UDP ${dhcp_port}" >&2
    exit 1
fi

stamped=$(stamped_address)
if [ -z "$stamped" ]; then
    echo "Error: [${log_tag}-healthcheck] PID 1 is not a dnsmasq relay" >&2
    exit 1
fi

if ! is_lan_address "$stamped"; then
    echo "Error: [${log_tag}-healthcheck] relaying as ${stamped}, but ${lan_ip_var} is ${DHCP_LAN_IP}; Pi-hole drops every request" >&2
    exit 1
fi
