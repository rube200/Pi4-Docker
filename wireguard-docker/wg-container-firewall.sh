#!/bin/sh
set -e

readonly IPT="iptables -w"
readonly IP6T="ip6tables -w"
readonly WG_CONFIG_DIR="/etc/wireguard"
readonly WG_FIREWALL_ENV="${WG_CONFIG_DIR}/wg-firewall.env"

require_var() {
    if [ -z "$2" ]; then
        echo "Error: [wg-firewall] $1 is not set in ${WG_FIREWALL_ENV}" >&2
        exit 1
    fi
}

dedup() {
    printf '%s' "$1" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' '
}

parse_ipv4() {
    case "$1" in
        ''|*[!0-9.]*|.*|*.|*..*) return 1 ;;
    esac
    _saved_ifs=$IFS
    IFS=.
    set -- $1
    IFS=$_saved_ifs
    [ "$#" -eq 4 ] || return 1
    for _octet in "$@"; do
        case "$_octet" in
            0) ;;
            0*) return 1 ;;
            *) [ "$_octet" -le 255 ] || return 1 ;;
        esac
    done
    octet1=$1
    octet2=$2
    octet3=$3
    octet4=$4
}

ACTION=$1
WIREGUARD_INTERFACE=$2

case "${ACTION}:${WIREGUARD_INTERFACE}" in
    up:?*|down:?*) ;;
    *)
        echo "Error: [wg-firewall] invalid usage" >&2
        echo "  Usage: $0 up|down <interface>" >&2
        exit 1
        ;;
esac

interface_config_path="${WG_CONFIG_DIR}/${WIREGUARD_INTERFACE}.conf"

if [ ! -f "$interface_config_path" ]; then
    echo "Error: [wg-firewall] ${interface_config_path} not found" >&2
    exit 1
fi

if [ ! -r "$WG_FIREWALL_ENV" ]; then
    echo "Error: [wg-firewall] ${WG_FIREWALL_ENV} not found" >&2
    exit 1
fi
. "$WG_FIREWALL_ENV"

require_var HOST_LAN_IP6 "$HOST_LAN_IP6"
require_var HOST_SERVER_HOSTNAME "$HOST_SERVER_HOSTNAME"
require_var WG_ALLOWLIST "$WG_ALLOWLIST"
require_var WG_DNS_IP "$WG_DNS_IP"
require_var WG_DNS_IP6 "$WG_DNS_IP6"
require_var WG_EGRESS_IFACE "$WG_EGRESS_IFACE"
require_var WG_FULL_ACCESS_MASK "$WG_FULL_ACCESS_MASK"
require_var WG_NGINX_IP "$WG_NGINX_IP"
require_var WG_NGINX_IP6 "$WG_NGINX_IP6"

masquerade_comment="wg-container-fw-masq-${WIREGUARD_INTERFACE}"

allowlist=
allowlist6=
for allowlist_item in $(printf '%s' "$WG_ALLOWLIST" | tr ',' ' '); do
    case "$allowlist_item" in
        *:*) allowlist6="$allowlist6 $allowlist_item" ;;
        *) allowlist="$allowlist $allowlist_item" ;;
    esac
done
allowlist=$(dedup "$allowlist")
allowlist6=$(dedup "$allowlist6")

configured_hosts=
configured_prefixes=
configured_hosts6=
configured_prefixes6=

while IFS= read -r config_line_raw || [ -n "$config_line_raw" ]; do
    config_line_trimmed=$(printf '%s' "$config_line_raw" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    case "$config_line_trimmed" in
        \#*) continue ;;
        [Aa][Dd][Dd][Rr][Ee][Ss][Ss][[:space:]]*=*) ;;
        *) continue ;;
    esac

    for address_token in $(printf '%s' "${config_line_trimmed#*=}" | tr ',' ' '); do
        case "$address_token" in
            *.*.*.*/*)
                address=${address_token%%/*}
                mask_field=${address_token#*/}
                case "$mask_field" in
                    ''|*[!0-9]*)
                        echo "Error: [wg-firewall] IPv4 Address= requires a numeric CIDR mask (${address_token} in ${interface_config_path})" >&2
                        exit 1
                        ;;
                esac
                prefix_length=$(printf '%s' "$mask_field" | sed 's/^0*//')
                prefix_length=${prefix_length:-0}
                if [ "$prefix_length" -eq 0 ]; then
                    echo "Error: [wg-firewall] IPv4 Address= prefix length cannot be 0 (${address_token} in ${interface_config_path})" >&2
                    exit 1
                fi
                if [ "$prefix_length" -gt 24 ]; then
                    echo "Error: [wg-firewall] IPv4 Address= prefix must be /24 or shorter, not /${prefix_length} (${address_token} in ${interface_config_path})" >&2
                    exit 1
                fi
                if ! parse_ipv4 "$address"; then
                    echo "Error: [wg-firewall] invalid IPv4 Address= host ${address} (${interface_config_path})" >&2
                    exit 1
                fi
                configured_hosts="$configured_hosts $address"
                packed=$(( (octet1 << 24) | (octet2 << 16) | (octet3 << 8) | octet4 ))
                host_bits=$((32 - prefix_length))
                network=$(( (packed >> host_bits) << host_bits ))
                configured_prefixes="$configured_prefixes $(( (network >> 24) & 255 )).$(( (network >> 16) & 255 )).$(( (network >> 8) & 255 )).$(( network & 255 ))/${prefix_length}"
                ;;
            *:*/*)
                address6=${address_token%%/*}
                mask_field6=${address_token#*/}
                case "$mask_field6" in
                    ''|*[!0-9]*)
                        echo "Error: [wg-firewall] IPv6 Address= requires a numeric CIDR mask (${address_token} in ${interface_config_path})" >&2
                        exit 1
                        ;;
                esac
                prefix_length6=$(printf '%s' "$mask_field6" | sed 's/^0*//')
                prefix_length6=${prefix_length6:-0}
                if [ "$prefix_length6" -eq 0 ]; then
                    echo "Error: [wg-firewall] IPv6 Address= prefix length cannot be 0 (${address_token} in ${interface_config_path})" >&2
                    exit 1
                fi
                if [ "$prefix_length6" -gt 64 ]; then
                    echo "Error: [wg-firewall] IPv6 Address= prefix must be /64 or shorter, not /${prefix_length6} (${address_token} in ${interface_config_path})" >&2
                    exit 1
                fi
                configured_hosts6="$configured_hosts6 $address6"
                network6=$(printf '%s' "$address6" | sed 's/::[0-9a-fA-F][0-9a-fA-F]*$/::/')
                configured_prefixes6="$configured_prefixes6 ${network6}/${prefix_length6}"
                ;;
        esac
    done
done <"$interface_config_path"

configured_hosts=$(dedup "$configured_hosts")
configured_prefixes=$(dedup "$configured_prefixes")
configured_hosts6=$(dedup "$configured_hosts6")
configured_prefixes6=$(dedup "$configured_prefixes6")

full_access=
for host_address in $configured_hosts; do
    full_access="$full_access ${host_address%.*}.0/${WG_FULL_ACCESS_MASK}"
done
full_access6=
for prefix_cidr6 in $configured_prefixes6; do
    full_access6="$full_access6 ${prefix_cidr6%%/*}/$((WG_FULL_ACCESS_MASK + 96))"
done

filter_chain="WG4-$WIREGUARD_INTERFACE"
filter_chain6="WG6-$WIREGUARD_INTERFACE"
nat_chain="WGNAT4-$WIREGUARD_INTERFACE"
nat_chain6="WGNAT6-$WIREGUARD_INTERFACE"

case "$ACTION" in
    up)
        if [ -z "$configured_prefixes" ] || [ -z "$configured_prefixes6" ]; then
            echo "Error: [wg-firewall] ${interface_config_path} needs an IPv4 and an IPv6 Address" >&2
            exit 1
        fi

        public_ip=
        for token in $(dig +time=2 +tries=1 +short A "$HOST_SERVER_HOSTNAME" @"$WG_DNS_IP" 2>/dev/null); do
            if parse_ipv4 "$token"; then
                public_ip=$token
                break
            fi
        done
        public_ip6=
        for token in $(dig +time=2 +tries=1 +short AAAA "$HOST_SERVER_HOSTNAME" @"$WG_DNS_IP" 2>/dev/null); do
            case "$token" in
                *:*)
                    public_ip6=$token
                    break
                    ;;
            esac
        done
        host_gateway=$(ip route show default 2>/dev/null | awk '{print $3; exit}')

        $IPT -N "$filter_chain" 2>/dev/null || $IPT -F "$filter_chain"
        $IPT -A "$filter_chain" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        $IPT -A "$filter_chain" -p udp -m multiport --dports 67,68 -j DROP
        for full_access_cidr in $full_access; do
            $IPT -A "$filter_chain" -s "$full_access_cidr" -j ACCEPT
        done
        for prefix_cidr in $configured_prefixes; do
            $IPT -A "$filter_chain" -d "$prefix_cidr" -j DROP
        done
        for proto in tcp udp; do
            $IPT -A "$filter_chain" -d "$WG_DNS_IP" -p "$proto" --dport 53 -j ACCEPT
        done
        for forward_dest in $allowlist; do
            $IPT -A "$filter_chain" -d "$forward_dest" -j ACCEPT
        done
        $IPT -A "$filter_chain" -d 127.0.0.0/8 -j DROP
        $IPT -A "$filter_chain" -d 10.0.0.0/8 -j DROP
        $IPT -A "$filter_chain" -d 169.254.0.0/16 -j DROP
        $IPT -A "$filter_chain" -d 172.16.0.0/12 -j DROP
        $IPT -A "$filter_chain" -d 192.168.0.0/16 -j DROP
        $IPT -A "$filter_chain" -j ACCEPT

        $IPT -C FORWARD -i "$WIREGUARD_INTERFACE" -j "$filter_chain" 2>/dev/null \
            || $IPT -A FORWARD -i "$WIREGUARD_INTERFACE" -j "$filter_chain"
        $IPT -C FORWARD -o "$WIREGUARD_INTERFACE" -j ACCEPT 2>/dev/null \
            || $IPT -A FORWARD -o "$WIREGUARD_INTERFACE" -j ACCEPT

        $IPT -t mangle -C FORWARD -o "$WIREGUARD_INTERFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
            || $IPT -t mangle -A FORWARD -o "$WIREGUARD_INTERFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

        $IP6T -N "$filter_chain6" 2>/dev/null || $IP6T -F "$filter_chain6"
        $IP6T -A "$filter_chain6" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        $IP6T -A "$filter_chain6" -p udp -m multiport --dports 546,547 -j DROP
        for full_access_cidr in $full_access6; do
            $IP6T -A "$filter_chain6" -s "$full_access_cidr" -j ACCEPT
        done
        for prefix_cidr6 in $configured_prefixes6; do
            $IP6T -A "$filter_chain6" -d "$prefix_cidr6" -j DROP
        done
        for proto in tcp udp; do
            $IP6T -A "$filter_chain6" -d "$WG_DNS_IP6" -p "$proto" --dport 53 -j ACCEPT
        done
        for forward_dest in $allowlist6; do
            $IP6T -A "$filter_chain6" -d "$forward_dest" -j ACCEPT
        done
        $IP6T -A "$filter_chain6" -d ::1/128 -j DROP
        $IP6T -A "$filter_chain6" -d fc00::/7 -j DROP
        $IP6T -A "$filter_chain6" -d fe80::/10 -j DROP
        $IP6T -A "$filter_chain6" -d "${HOST_LAN_IP6}/64" -j DROP
        if [ -n "$public_ip6" ]; then
            $IP6T -A "$filter_chain6" -d "${public_ip6}/64" -j DROP
            $IP6T -A "$filter_chain6" -j ACCEPT
        else
            $IP6T -A "$filter_chain6" -j DROP
        fi

        $IP6T -C FORWARD -i "$WIREGUARD_INTERFACE" -j "$filter_chain6" 2>/dev/null \
            || $IP6T -A FORWARD -i "$WIREGUARD_INTERFACE" -j "$filter_chain6"
        $IP6T -C FORWARD -o "$WIREGUARD_INTERFACE" -j ACCEPT 2>/dev/null \
            || $IP6T -A FORWARD -o "$WIREGUARD_INTERFACE" -j ACCEPT

        $IP6T -t mangle -C FORWARD -o "$WIREGUARD_INTERFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
            || $IP6T -t mangle -A FORWARD -o "$WIREGUARD_INTERFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

        $IPT -t nat -N "$nat_chain" 2>/dev/null || $IPT -t nat -F "$nat_chain"
        $IPT -t nat -C PREROUTING -i "$WIREGUARD_INTERFACE" -j "$nat_chain" 2>/dev/null \
            || $IPT -t nat -A PREROUTING -i "$WIREGUARD_INTERFACE" -j "$nat_chain"
        for prefix_cidr in $configured_prefixes; do
            $IPT -t nat -C POSTROUTING -s "$prefix_cidr" -o "$WG_EGRESS_IFACE" -m comment --comment "$masquerade_comment" -j MASQUERADE 2>/dev/null \
                || $IPT -t nat -A POSTROUTING -s "$prefix_cidr" -o "$WG_EGRESS_IFACE" -m comment --comment "$masquerade_comment" -j MASQUERADE
        done

        for dns_client in $configured_hosts; do
            for proto in tcp udp; do
                $IPT -t nat -A "$nat_chain" -d "$dns_client" -p "$proto" --dport 53 -j DNAT --to-destination "${WG_DNS_IP}:53"
            done
        done

        if [ -n "$public_ip" ] && parse_ipv4 "$host_gateway"; then
            for full_access_cidr in $full_access; do
                $IPT -t nat -A "$nat_chain" -s "$full_access_cidr" -d "$public_ip" -j DNAT --to-destination "$host_gateway"
            done
            $IPT -t nat -A "$nat_chain" -d "$public_ip" -j DNAT --to-destination "$WG_NGINX_IP"
        else
            echo "Warning: [wg-firewall] failed to resolve the public IPv4 of HOST_SERVER_HOSTNAME or the host gateway" >&2
        fi

        $IP6T -t nat -N "$nat_chain6" 2>/dev/null || $IP6T -t nat -F "$nat_chain6"
        $IP6T -t nat -C PREROUTING -i "$WIREGUARD_INTERFACE" -j "$nat_chain6" 2>/dev/null \
            || $IP6T -t nat -A PREROUTING -i "$WIREGUARD_INTERFACE" -j "$nat_chain6"
        for prefix_cidr6 in $configured_prefixes6; do
            $IP6T -t nat -C POSTROUTING -s "$prefix_cidr6" -o "$WG_EGRESS_IFACE" -m comment --comment "$masquerade_comment" -j MASQUERADE 2>/dev/null \
                || $IP6T -t nat -A POSTROUTING -s "$prefix_cidr6" -o "$WG_EGRESS_IFACE" -m comment --comment "$masquerade_comment" -j MASQUERADE
        done

        for dns_client6 in $configured_hosts6; do
            for proto in tcp udp; do
                $IP6T -t nat -A "$nat_chain6" -d "$dns_client6" -p "$proto" --dport 53 -j DNAT --to-destination "[${WG_DNS_IP6}]:53"
            done
        done

        if [ -n "$public_ip6" ]; then
            for full_access_cidr in $full_access6; do
                $IP6T -t nat -A "$nat_chain6" -s "$full_access_cidr" -d "$public_ip6" -j RETURN
            done
            $IP6T -t nat -A "$nat_chain6" -d "$public_ip6" -j DNAT --to-destination "$WG_NGINX_IP6"
        else
            echo "Warning: [wg-firewall] failed to resolve the public IPv6 of HOST_SERVER_HOSTNAME" >&2
            echo "  Internet only clients get no IPv6 internet until wireguard restarts" >&2
        fi
        ;;
    down)
        set +e

        $IPT -t nat -D PREROUTING -i "$WIREGUARD_INTERFACE" -j "$nat_chain" 2>/dev/null
        $IPT -t nat -F "$nat_chain" 2>/dev/null
        $IPT -t nat -X "$nat_chain" 2>/dev/null
        for prefix_cidr in $configured_prefixes; do
            $IPT -t nat -D POSTROUTING -s "$prefix_cidr" -o "$WG_EGRESS_IFACE" -m comment --comment "$masquerade_comment" -j MASQUERADE 2>/dev/null
        done

        $IP6T -t nat -D PREROUTING -i "$WIREGUARD_INTERFACE" -j "$nat_chain6" 2>/dev/null
        $IP6T -t nat -F "$nat_chain6" 2>/dev/null
        $IP6T -t nat -X "$nat_chain6" 2>/dev/null
        for prefix_cidr6 in $configured_prefixes6; do
            $IP6T -t nat -D POSTROUTING -s "$prefix_cidr6" -o "$WG_EGRESS_IFACE" -m comment --comment "$masquerade_comment" -j MASQUERADE 2>/dev/null
        done

        $IPT -t mangle -D FORWARD -o "$WIREGUARD_INTERFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
        $IPT -D FORWARD -o "$WIREGUARD_INTERFACE" -j ACCEPT 2>/dev/null
        $IPT -D FORWARD -i "$WIREGUARD_INTERFACE" -j "$filter_chain" 2>/dev/null
        $IPT -F "$filter_chain" 2>/dev/null
        $IPT -X "$filter_chain" 2>/dev/null

        $IP6T -t mangle -D FORWARD -o "$WIREGUARD_INTERFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
        $IP6T -D FORWARD -o "$WIREGUARD_INTERFACE" -j ACCEPT 2>/dev/null
        $IP6T -D FORWARD -i "$WIREGUARD_INTERFACE" -j "$filter_chain6" 2>/dev/null
        $IP6T -F "$filter_chain6" 2>/dev/null
        $IP6T -X "$filter_chain6" 2>/dev/null

        set -e
        ;;
esac
