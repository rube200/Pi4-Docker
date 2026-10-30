#!/bin/sh

readonly WAITING_MARKER="/run/relay-waiting"

case "$DHCP_SERVER" in
    *:*)
        dhcp_family=6
        dhcp_port=547
        dhcp_port_hex=0223
        dhcp_proc=/proc/net/udp6
        log_tag=dhcpv6-relay
        lan_ip_var=HOST_LAN_IP6
        lan_prefix_len=64
        ;;
    *)
        dhcp_family=4
        dhcp_port=67
        dhcp_port_hex=0043
        dhcp_proc=/proc/net/udp
        log_tag=dhcp-relay
        lan_ip_var=HOST_LAN_IP
        lan_prefix_len=32
        ;;
esac

global_addresses() {
    ip -"$dhcp_family" -o addr show dev "$DHCP_IFACE" scope global "$@" 2>/dev/null \
        | grep -v ' temporary' \
        | grep -v ' deprecated' \
        | grep -v ' secondary' \
        | awk '{print $4}' | cut -d/ -f1
}

lan_addresses() {
    global_addresses to "${DHCP_LAN_IP}/${lan_prefix_len}"
}

is_lan_address() {
    lan_addresses | grep -qxF "$1"
}
