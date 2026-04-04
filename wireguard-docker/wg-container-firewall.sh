#!/bin/sh
set -e

IPT="iptables -w"
IP6T="ip6tables -w"

ACTION=${1-}
WIREGUARD_INTERFACE=${2-}

case "$ACTION" in
    up | down)
        [ -n "$WIREGUARD_INTERFACE" ] || {
            echo "WireGuard firewall: interface name is missing (second argument)." >&2
            exit 1
        }
        ;;
    *)
        echo "WireGuard firewall: invalid usage." >&2
        echo "  Expected: $0 up <interface>   (typically from PostUp)" >&2
        echo "            $0 down <interface> (typically from PostDown)" >&2
        exit 1
        ;;
esac

WIREGUARD_CONFIG_DIR=/etc/wireguard
INTERFACE_CONFIG_PATH=$WIREGUARD_CONFIG_DIR/$WIREGUARD_INTERFACE.conf
FIREWALL_ENV_PATH=$WIREGUARD_CONFIG_DIR/wg-firewall.env

[ -f "$INTERFACE_CONFIG_PATH" ] || {
    echo "WireGuard firewall: interface configuration not found: $INTERFACE_CONFIG_PATH" >&2
    exit 1
}
[ -r "$FIREWALL_ENV_PATH" ] || {
    echo "WireGuard firewall: policy file missing or unreadable: $FIREWALL_ENV_PATH (container entrypoint must create it before WireGuard starts)." >&2
    exit 1
}
. "$FIREWALL_ENV_PATH"
[ -n "${SERVER_HOSTNAME}" ] || {
    echo "WireGuard firewall: SERVER_HOSTNAME is not set in $FIREWALL_ENV_PATH (container entrypoint must export it before WireGuard starts)." >&2
    exit 1
}
[ -n "${LOCAL_DNS_IP}" ] || {
    echo "WireGuard firewall: LOCAL_DNS_IP is not set in $FIREWALL_ENV_PATH (set it in the container environment, e.g. docker-compose)." >&2
    exit 1
}
[ -n "${LOCAL_ALLOWLIST}" ] || {
    echo "WireGuard firewall: LOCAL_ALLOWLIST is not set in $FIREWALL_ENV_PATH (set it in the container environment, e.g. docker-compose)." >&2
    exit 1
}
[ -n "${WG_EGRESS_IFACE}" ] || {
    echo "WireGuard firewall: WG_EGRESS_IFACE is not set in $FIREWALL_ENV_PATH (set it in the container environment, e.g. docker-compose)." >&2
    exit 1
}
if [ -n "${LOCAL_DNS_IPV6:-}" ]; then
    LOCAL_DNS_IPV6=${LOCAL_DNS_IPV6#\[}
    LOCAL_DNS_IPV6=${LOCAL_DNS_IPV6%\]}
fi

MASQUERADE_COMMENT="wg-container-fw-masq-${WIREGUARD_INTERFACE}"

ALLOWLIST_V4=
ALLOWLIST_V6=
if [ -n "$LOCAL_ALLOWLIST" ]; then
    saved_IFS=$IFS
    IFS=,
    for allowlist_item in $LOCAL_ALLOWLIST; do
        IFS=$saved_IFS
        allowlist_item=$(echo "$allowlist_item" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$allowlist_item" ] && continue
        case "$allowlist_item" in
            *:*) ALLOWLIST_V6="$ALLOWLIST_V6 $allowlist_item" ;;
            *) ALLOWLIST_V4="$ALLOWLIST_V4 $allowlist_item" ;;
        esac
        IFS=,
    done
    IFS=$saved_IFS
fi
ALLOWLIST_V4=$(echo "$ALLOWLIST_V4" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ')
ALLOWLIST_V6=$(echo "$ALLOWLIST_V6" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ')

configured_ipv4_hosts=
configured_ipv4_prefixes=
configured_ipv6_hosts=
configured_ipv6_prefixes=

while IFS= read -r config_line_raw || [ -n "$config_line_raw" ]; do
    config_line_trimmed=$(printf '%s' "$config_line_raw" | tr -d '\r')
    config_line_trimmed=$(echo "$config_line_trimmed" | sed 's/^[[:space:]]*//')
    case "$config_line_trimmed" in
        \#*) continue ;;
        [Aa][Dd][Dd][Rr][Ee][Ss][Ss][[:space:]]*=*) ;;
        *) continue ;;
    esac

    address_field_value=${config_line_trimmed#*=}
    address_field_value=$(echo "$address_field_value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$address_field_value" ] && continue

    saved_IFS=$IFS
    IFS=,
    for address_token in $address_field_value; do
        IFS=$saved_IFS
        address_token=$(echo "$address_token" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$address_token" ] && continue

        case "$address_token" in
            *.*.*.*/*)
                ipv4_host=${address_token%%/*}
                ipv4_mask_field=${address_token#*/}
                case "$ipv4_mask_field" in
                    ''|*[!0-9]*)
                        echo "WireGuard firewall: IPv4 Address= requires a numeric CIDR mask ($address_token in $INTERFACE_CONFIG_PATH)." >&2
                        exit 1
                        ;;
                esac
                ipv4_prefix_length=$(echo "$ipv4_mask_field" | sed 's/^0*//')
                [ -z "$ipv4_prefix_length" ] && ipv4_prefix_length=0
                if [ "$ipv4_prefix_length" -eq 0 ]; then
                    echo "WireGuard firewall: IPv4 Address= prefix length cannot be 0 ($address_token in $INTERFACE_CONFIG_PATH)." >&2
                    exit 1
                fi
                configured_ipv4_hosts="$configured_ipv4_hosts $ipv4_host"
                if [ "$ipv4_prefix_length" -gt 24 ]; then
                    echo "WireGuard firewall: IPv4 Address= prefix must be /24 or shorter (/25-/32 are not supported), not /$ipv4_prefix_length ($address_token in $INTERFACE_CONFIG_PATH)." >&2
                    exit 1
                fi
                if [ "$ipv4_prefix_length" -ge 1 ] && [ "$ipv4_prefix_length" -le 24 ]; then
                    ipv4_o1=$(echo "$ipv4_host" | cut -d. -f1)
                    ipv4_o2=$(echo "$ipv4_host" | cut -d. -f2)
                    ipv4_o3=$(echo "$ipv4_host" | cut -d. -f3)
                    ipv4_o4=$(echo "$ipv4_host" | cut -d. -f4)
                    ipv4_o5=$(echo "$ipv4_host" | cut -d. -f5)
                    ipv4_parse_err=
                    for ipv4_octet in "$ipv4_o1" "$ipv4_o2" "$ipv4_o3" "$ipv4_o4"; do
                        case "$ipv4_octet" in
                            ''|*[!0-9]*) ipv4_parse_err=1 ;;
                            0) ;;
                            0*) ipv4_parse_err=1 ;;
                        esac
                    done
                    [ -n "$ipv4_o5" ] && ipv4_parse_err=1
                    if [ -n "$ipv4_parse_err" ] || [ "$ipv4_o1" -gt 255 ] || [ "$ipv4_o2" -gt 255 ] || [ "$ipv4_o3" -gt 255 ] || [ "$ipv4_o4" -gt 255 ]; then
                        echo "WireGuard firewall: invalid IPv4 Address= host $ipv4_host ($INTERFACE_CONFIG_PATH)." >&2
                        exit 1
                    fi
                    ipv4_packed=$(( (ipv4_o1 << 24) | (ipv4_o2 << 16) | (ipv4_o3 << 8) | ipv4_o4 ))
                    ipv4_hostbits=$((32 - ipv4_prefix_length))
                    ipv4_net=$(( (ipv4_packed >> ipv4_hostbits) << ipv4_hostbits ))
                    ipv4_n1=$(( (ipv4_net >> 24) & 255 ))
                    ipv4_n2=$(( (ipv4_net >> 16) & 255 ))
                    ipv4_n3=$(( (ipv4_net >> 8) & 255 ))
                    ipv4_n4=$(( ipv4_net & 255 ))
                    configured_ipv4_prefixes="$configured_ipv4_prefixes $ipv4_n1.$ipv4_n2.$ipv4_n3.$ipv4_n4/$ipv4_prefix_length"
                fi
                ;;
            *:*/*)
                ipv6_address=${address_token%%/*}
                ipv6_mask_field=${address_token#*/}
                case "$ipv6_mask_field" in
                    ''|*[!0-9]*)
                        echo "WireGuard firewall: IPv6 Address= requires a numeric CIDR mask ($address_token in $INTERFACE_CONFIG_PATH)." >&2
                        exit 1
                        ;;
                esac
                ipv6_prefix_length=$(echo "$ipv6_mask_field" | sed 's/^0*//')
                [ -z "$ipv6_prefix_length" ] && ipv6_prefix_length=0
                if [ "$ipv6_prefix_length" -eq 0 ]; then
                    echo "WireGuard firewall: IPv6 Address= prefix length cannot be 0 ($address_token in $INTERFACE_CONFIG_PATH)." >&2
                    exit 1
                fi
                configured_ipv6_hosts="$configured_ipv6_hosts $ipv6_address"
                if [ "$ipv6_prefix_length" -gt 64 ]; then
                    echo "WireGuard firewall: IPv6 Address= prefix must be /64 or shorter (/65 and longer are not supported), not /$ipv6_prefix_length ($address_token in $INTERFACE_CONFIG_PATH)." >&2
                    exit 1
                fi
                if [ "$ipv6_prefix_length" -ge 1 ] && [ "$ipv6_prefix_length" -le 64 ]; then
                    ipv6_network_prefix=$(echo "$ipv6_address" | sed 's/::[0-9a-fA-F][0-9a-fA-F]*$/::/')
                    configured_ipv6_prefixes="$configured_ipv6_prefixes $ipv6_network_prefix/$ipv6_prefix_length"
                fi
                ;;
        esac
        IFS=,
    done
    IFS=$saved_IFS
done <"$INTERFACE_CONFIG_PATH"

configured_ipv4_hosts=$(echo "$configured_ipv4_hosts" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ')
configured_ipv4_prefixes=$(echo "$configured_ipv4_prefixes" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ')
configured_ipv6_hosts=$(echo "$configured_ipv6_hosts" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ')
configured_ipv6_prefixes=$(echo "$configured_ipv6_prefixes" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ')

FILTER_CHAIN_V4="WG4-$WIREGUARD_INTERFACE"
FILTER_CHAIN_V6="WG6-$WIREGUARD_INTERFACE"

NAT_CHAIN_V4="WGNAT4-$WIREGUARD_INTERFACE"
NAT_CHAIN_V6="WGNAT6-$WIREGUARD_INTERFACE"

ip6tables_available=0
command -v ip6tables >/dev/null 2>&1 && ip6tables_available=1

hairpin_public_v4=
hairpin_target_v4=

if command -v dig >/dev/null 2>&1 && [ -n "${SERVER_HOSTNAME}" ]; then
    for token in $(dig +time=2 +tries=1 +short A "${SERVER_HOSTNAME}" @"${LOCAL_DNS_IP}" 2>/dev/null); do
        case "$token" in
            *[!0-9.]*|'') continue ;;
        esac
        a=${token%%.*}; rest=${token#*.}
        [ "$rest" = "$token" ] && continue
        b=${rest%%.*}; rest=${rest#*.}
        [ "$rest" = "$b" ] && continue
        c=${rest%%.*}; d=${rest#*.}
        case "$d" in *.*|'') continue ;; esac
        valid=1
        for oct in "$a" "$b" "$c" "$d"; do
            case "$oct" in ''|*[!0-9]*) valid=0 ;; esac
            [ "$oct" -gt 255 ] 2>/dev/null && valid=0
        done
        [ "$valid" -eq 1 ] || continue
        hairpin_public_v4=$token
        break
    done
fi

if command -v ip >/dev/null 2>&1; then
    gw=$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')
    case "$gw" in
        *[!0-9.]*|'') ;;
        *) hairpin_target_v4=$gw ;;
    esac
fi

case "$ACTION" in
up)
    wg_has_v4=0
    wg_has_v6=0
    [ -n "$configured_ipv4_hosts$configured_ipv4_prefixes$ALLOWLIST_V4" ] && wg_has_v4=1
    [ -n "$configured_ipv6_hosts$configured_ipv6_prefixes$ALLOWLIST_V6" ] && wg_has_v6=1

    if [ "$wg_has_v4" -eq 1 ]; then
        $IPT -N "$FILTER_CHAIN_V4" 2>/dev/null || $IPT -F "$FILTER_CHAIN_V4"
        $IPT -A "$FILTER_CHAIN_V4" -p udp -m multiport --dports 67,68 -j DROP
        for ipv4_prefix_cidr in $configured_ipv4_prefixes; do
            ipv4_prefix_net=${ipv4_prefix_cidr%%/*}
            $IPT -A "$FILTER_CHAIN_V4" -d "$ipv4_prefix_cidr" -j ACCEPT
            $IPT -A "$FILTER_CHAIN_V4" -s "${ipv4_prefix_net}/30" -j ACCEPT
        done
        for forward_dest in $ALLOWLIST_V4; do
            $IPT -A "$FILTER_CHAIN_V4" -d "$forward_dest" -j ACCEPT
        done
        $IPT -A "$FILTER_CHAIN_V4" -p tcp --dport 22 -j DROP
        $IPT -A "$FILTER_CHAIN_V4" -d 127.0.0.0/8 -j DROP
        $IPT -A "$FILTER_CHAIN_V4" -d 192.168.0.0/16 -j DROP
        $IPT -A "$FILTER_CHAIN_V4" -d 172.16.0.0/12 -j DROP
        $IPT -A "$FILTER_CHAIN_V4" -d 10.0.0.0/8 -j DROP
        $IPT -A "$FILTER_CHAIN_V4" -j ACCEPT

        $IPT -C FORWARD -o "$WIREGUARD_INTERFACE" -j ACCEPT 2>/dev/null \
            || $IPT -A FORWARD -o "$WIREGUARD_INTERFACE" -j ACCEPT
        $IPT -C FORWARD -i "$WIREGUARD_INTERFACE" -j "$FILTER_CHAIN_V4" 2>/dev/null \
            || $IPT -A FORWARD -i "$WIREGUARD_INTERFACE" -j "$FILTER_CHAIN_V4"
    fi

    if [ "$ip6tables_available" -eq 1 ] && [ "$wg_has_v6" -eq 1 ]; then
        $IP6T -N "$FILTER_CHAIN_V6" 2>/dev/null || $IP6T -F "$FILTER_CHAIN_V6"
        $IP6T -A "$FILTER_CHAIN_V6" -p udp -m multiport --dports 546,547 -j DROP
        for ipv6_prefix_cidr in $configured_ipv6_prefixes; do
            ipv6_prefix_net=${ipv6_prefix_cidr%%/*}
            $IP6T -A "$FILTER_CHAIN_V6" -d "$ipv6_prefix_cidr" -j ACCEPT
            $IP6T -A "$FILTER_CHAIN_V6" -s "${ipv6_prefix_net}/126" -j ACCEPT
        done
        for forward_dest in $ALLOWLIST_V6; do
            $IP6T -A "$FILTER_CHAIN_V6" -d "$forward_dest" -j ACCEPT
        done
        $IP6T -A "$FILTER_CHAIN_V6" -p tcp --dport 22 -j DROP
        $IP6T -A "$FILTER_CHAIN_V6" -d ::1/128 -j DROP
        $IP6T -A "$FILTER_CHAIN_V6" -d fc00::/7 -j DROP
        $IP6T -A "$FILTER_CHAIN_V6" -d fe80::/10 -j DROP
        $IP6T -A "$FILTER_CHAIN_V6" -j ACCEPT

        $IP6T -C FORWARD -o "$WIREGUARD_INTERFACE" -j ACCEPT 2>/dev/null \
            || $IP6T -A FORWARD -o "$WIREGUARD_INTERFACE" -j ACCEPT
        $IP6T -C FORWARD -i "$WIREGUARD_INTERFACE" -j "$FILTER_CHAIN_V6" 2>/dev/null \
            || $IP6T -A FORWARD -i "$WIREGUARD_INTERFACE" -j "$FILTER_CHAIN_V6"
    fi

    if [ "$wg_has_v4" -eq 1 ]; then
        $IPT -t nat -N "$NAT_CHAIN_V4" 2>/dev/null || $IPT -t nat -F "$NAT_CHAIN_V4"
        $IPT -t nat -C PREROUTING -i "$WIREGUARD_INTERFACE" -j "$NAT_CHAIN_V4" 2>/dev/null \
            || $IPT -t nat -A PREROUTING -i "$WIREGUARD_INTERFACE" -j "$NAT_CHAIN_V4"
        $IPT -t nat -C POSTROUTING -o "$WG_EGRESS_IFACE" -m comment --comment "$MASQUERADE_COMMENT" -j MASQUERADE 2>/dev/null \
            || $IPT -t nat -A POSTROUTING -o "$WG_EGRESS_IFACE" -m comment --comment "$MASQUERADE_COMMENT" -j MASQUERADE

        for dns_client_ipv4 in $configured_ipv4_hosts; do
            for proto in udp tcp; do
                $IPT -t nat -C "$NAT_CHAIN_V4" -d "$dns_client_ipv4" -p "$proto" --dport 53 -j DNAT \
                    --to-destination "${LOCAL_DNS_IP}:53" 2>/dev/null \
                    || $IPT -t nat -A "$NAT_CHAIN_V4" -d "$dns_client_ipv4" -p "$proto" --dport 53 -j DNAT \
                    --to-destination "${LOCAL_DNS_IP}:53"
            done
        done

        if [ -n "$hairpin_public_v4" ] && [ -n "$hairpin_target_v4" ]; then
            $IPT -t nat -C "$NAT_CHAIN_V4" -d "$hairpin_public_v4" -j DNAT --to-destination "$hairpin_target_v4" 2>/dev/null \
                || $IPT -t nat -A "$NAT_CHAIN_V4" -d "$hairpin_public_v4" -j DNAT --to-destination "$hairpin_target_v4"
        else
            echo "WireGuard hairpin: failed to resolve public IP from SERVER_HOSTNAME or host gateway IP." >&2
        fi
    fi

    if [ "$ip6tables_available" -eq 1 ] && [ "$wg_has_v6" -eq 1 ]; then
        $IP6T -t nat -N "$NAT_CHAIN_V6" 2>/dev/null || $IP6T -t nat -F "$NAT_CHAIN_V6"
        $IP6T -t nat -C PREROUTING -i "$WIREGUARD_INTERFACE" -j "$NAT_CHAIN_V6" 2>/dev/null \
            || $IP6T -t nat -A PREROUTING -i "$WIREGUARD_INTERFACE" -j "$NAT_CHAIN_V6"
        $IP6T -t nat -C POSTROUTING -o "$WG_EGRESS_IFACE" -m comment --comment "$MASQUERADE_COMMENT" -j MASQUERADE 2>/dev/null \
            || $IP6T -t nat -A POSTROUTING -o "$WG_EGRESS_IFACE" -m comment --comment "$MASQUERADE_COMMENT" -j MASQUERADE

        if [ -n "${LOCAL_DNS_IPV6:-}" ]; then
            for dns_client_ipv6 in $configured_ipv6_hosts; do
                for proto in udp tcp; do
                    $IP6T -t nat -C "$NAT_CHAIN_V6" -d "$dns_client_ipv6" -p "$proto" --dport 53 -j DNAT \
                        --to-destination "[${LOCAL_DNS_IPV6}]:53" 2>/dev/null \
                        || $IP6T -t nat -A "$NAT_CHAIN_V6" -d "$dns_client_ipv6" -p "$proto" --dport 53 -j DNAT \
                        --to-destination "[${LOCAL_DNS_IPV6}]:53"
                done
            done
        fi
    fi
    ;;
down)
    set +e

    if [ "$ip6tables_available" -eq 1 ]; then
        $IP6T -t nat -D PREROUTING -i "$WIREGUARD_INTERFACE" -j "$NAT_CHAIN_V6" 2>/dev/null
        $IP6T -t nat -F "$NAT_CHAIN_V6" 2>/dev/null
        $IP6T -t nat -X "$NAT_CHAIN_V6" 2>/dev/null
        $IP6T -t nat -D POSTROUTING -o "$WG_EGRESS_IFACE" -m comment --comment "$MASQUERADE_COMMENT" -j MASQUERADE 2>/dev/null
    fi

    $IPT -t nat -D PREROUTING -i "$WIREGUARD_INTERFACE" -j "$NAT_CHAIN_V4" 2>/dev/null
    $IPT -t nat -F "$NAT_CHAIN_V4" 2>/dev/null
    $IPT -t nat -X "$NAT_CHAIN_V4" 2>/dev/null
    $IPT -t nat -D POSTROUTING -o "$WG_EGRESS_IFACE" -m comment --comment "$MASQUERADE_COMMENT" -j MASQUERADE 2>/dev/null

    if [ "$ip6tables_available" -eq 1 ]; then
        $IP6T -D FORWARD -o "$WIREGUARD_INTERFACE" -j ACCEPT 2>/dev/null
        $IP6T -D FORWARD -i "$WIREGUARD_INTERFACE" -j "$FILTER_CHAIN_V6" 2>/dev/null
        $IP6T -F "$FILTER_CHAIN_V6" 2>/dev/null
        $IP6T -X "$FILTER_CHAIN_V6" 2>/dev/null
    fi

    $IPT -D FORWARD -o "$WIREGUARD_INTERFACE" -j ACCEPT 2>/dev/null
    $IPT -D FORWARD -i "$WIREGUARD_INTERFACE" -j "$FILTER_CHAIN_V4" 2>/dev/null
    $IPT -F "$FILTER_CHAIN_V4" 2>/dev/null
    $IPT -X "$FILTER_CHAIN_V4" 2>/dev/null

    set -e
    ;;
esac
