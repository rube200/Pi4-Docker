#!/bin/sh
set -e

readonly WG_CONFIG_DIR="/etc/wireguard"
readonly DEFAULT_WG_PORT=51820
readonly DEFAULT_WG_CONTAINER="wireguard"

cd "$WG_CONFIG_DIR" || exit 1
umask 077

SERVER_PORT="${WIREGUARD_PORT:-$DEFAULT_WG_PORT}"
WIREGUARD_CONTAINER="${WIREGUARD_CONTAINER:-$DEFAULT_WG_CONTAINER}"

WG_LIST=$(for _f in wg*.conf; do [ -f "$_f" ] && echo "$_f"; done | sort)
if [ -z "$WG_LIST" ]; then
    echo "Error: no wg*.conf found in ${WG_CONFIG_DIR}" >&2
    exit 1
fi

WG_COUNT=$(echo "$WG_LIST" | wc -l | tr -d ' \t')
if [ "$WG_COUNT" -eq 1 ]; then
    WIREGUARD_CONFIG="$WG_LIST"
else
    echo "Available WireGuard server configs:"
    echo "$WG_LIST" | while IFS= read -r _line; do
        [ -z "$_line" ] && continue
        _i=$((_i + 1))
        echo "  ${_i}) ${_line} ($(basename "$_line" .conf))"
    done
    _i=$WG_COUNT
    while :; do
        echo -n "Select interface [1-${_i}]: "
        read -r _sel
        case "$_sel" in
            ''|*[!0-9]*)
                echo "Enter a number between 1 and ${_i}."
                ;;
            *)
                if [ -n "$_sel" ] && [ "$_sel" -ge 1 ] && [ "$_sel" -le "$_i" ]; then
                    WIREGUARD_CONFIG=$(echo "$WG_LIST" | sed -n "${_sel}p")
                    break
                fi
                echo "Enter a number between 1 and ${_i}."
                ;;
        esac
    done
fi

WIREGUARD_INTERFACE=$(basename "$WIREGUARD_CONFIG" .conf)
SERVER_CONFIG="${WG_CONFIG_DIR}/${WIREGUARD_CONFIG}"

if [ ! -r "$SERVER_CONFIG" ]; then
    echo "Error: Server config $SERVER_CONFIG not found or not readable" >&2
    exit 1
fi

if command -v wg >/dev/null 2>&1; then
    WG_CMD="wg"
elif docker ps --format '{{.Names}}' | grep -q "^${WIREGUARD_CONTAINER}$"; then
    WG_CMD="docker exec ${WIREGUARD_CONTAINER} wg"
else
    echo "Error: 'wg' command not available and WireGuard container '${WIREGUARD_CONTAINER}' not running" >&2
    exit 1
fi

if [ "$WG_CMD" = "wg" ]; then
    SERVER_PUBLIC_KEY=$(grep "^PrivateKey" "$SERVER_CONFIG" | awk '{print $3}' | wg pubkey)
else
    SERVER_PUBLIC_KEY=$(grep "^PrivateKey" "$SERVER_CONFIG" | awk '{print $3}' | docker exec -i "${WIREGUARD_CONTAINER}" wg pubkey)
fi
if [ -z "$SERVER_PUBLIC_KEY" ]; then
    echo "Error: Could not extract server public key from $SERVER_CONFIG" >&2
    exit 1
fi

ADDRESS_LINE=$(grep "^Address" "$SERVER_CONFIG" | head -1)
SERVER_ADDRESS=$(echo "$ADDRESS_LINE" | awk '{print $3}' | cut -d',' -f1 | cut -d'/' -f1)
if echo "$ADDRESS_LINE" | grep -q ","; then
    SERVER_ADDRESS6=$(echo "$ADDRESS_LINE" | awk '{print $4}' | cut -d'/' -f1)
else
    SERVER_ADDRESS6=""
fi

if [ -z "$SERVER_ADDRESS" ]; then
    echo "Error: Could not determine server address" >&2
    exit 1
fi

echo
echo "Server: ${WIREGUARD_CONFIG} (interface ${WIREGUARD_INTERFACE})"

SUBNET=$(echo "$SERVER_ADDRESS" | cut -d'.' -f1-3)
if [ -n "$SERVER_ADDRESS6" ]; then
    if echo "$SERVER_ADDRESS6" | grep -q "::"; then
        SUBNET6=$(echo "$SERVER_ADDRESS6" | sed 's/::.*$/::/')
    else
        SUBNET6=$(echo "$SERVER_ADDRESS6" | cut -d':' -f1-5)
    fi
else
    SUBNET6=""
fi

echo
echo "Provide a name for the client:"
read -p "Name: " unsanitized_client
client=$(echo "$unsanitized_client" | sed 's/[^0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-]/_/g')
while [ -z "$client" ] || [ -f "${WG_CONFIG_DIR}/${client}.conf" ]; do
    echo "${client}: Invalid name or already exists."
    read -p "Name: " unsanitized_client
    client=$(echo "$unsanitized_client" | sed 's/[^0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-]/_/g')
done

max_count=1
if [ -r "$SERVER_CONFIG" ]; then
    while IFS= read -r line; do
        ip=$(echo "$line" | sed -n 's/.*AllowedIPs = \([0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+\).*/\1/p')
        if [ -n "$ip" ]; then
            last_octet=$(echo "$ip" | cut -d'.' -f4)
            if [ "$last_octet" -ge 2 ] && [ "$last_octet" -le 254 ] && [ "$last_octet" -gt "$max_count" ]; then
                max_count=$last_octet
            fi
        fi
    done <<EOF
$(grep "^AllowedIPs = " "$SERVER_CONFIG")
EOF
fi

count=$((max_count + 1))
if [ "$count" -lt 2 ] || [ "$count" -gt 254 ]; then
    echo "Error: Could not find a valid IP address (next would be ${count}, must be 2-254)" >&2
    exit 1
fi

echo
echo "Using client IP: ${SUBNET}.${count}"
client_ip="${SUBNET}.${count}"
if [ -n "$SERVER_ADDRESS6" ]; then
    if [ "${SUBNET6%::}" != "$SUBNET6" ]; then
        client_ip6="${SUBNET6}${count}"
    else
        client_ip6="${SUBNET6}::${count}"
    fi
else
    client_ip6=""
fi

echo
echo "Choose VPN type:"
echo "   1) Full VPN (route all traffic)"
echo "   2) Split VPN (only VPN network)"
read -p "Type [1-2]: " type
while [ "$type" != "1" ] && [ "$type" != "2" ]; do
    echo "${type}: Invalid selection."
    read -p "Type [1-2]: " type
done

case "$type" in
    1)
        AllowedIPs="0.0.0.0/0"
        if [ -n "$client_ip6" ]; then
            AllowedIPs="${AllowedIPs}, ::/0"
        fi
        ;;
    2)
        SUBNET_MASK=$(echo "$SERVER_ADDRESS" | cut -d'/' -f2)
        if [ -z "$SUBNET_MASK" ]; then
            SUBNET_MASK="24"
        fi
        AllowedIPs="${SUBNET}.0/${SUBNET_MASK}"
        if [ -n "$client_ip6" ]; then
            SUBNET6_MASK=$(echo "$SERVER_ADDRESS6" | cut -d'/' -f2)
            if [ -z "$SUBNET6_MASK" ]; then
                SUBNET6_MASK="64"
            fi
            AllowedIPs="${AllowedIPs}, ${SUBNET6}/${SUBNET6_MASK}"
        fi
        ;;
esac

PRIVATE_KEY=$($WG_CMD genkey)
if [ "$WG_CMD" = "wg" ]; then
    PUBLIC_KEY=$(echo "$PRIVATE_KEY" | wg pubkey)
else
    PUBLIC_KEY=$(echo "$PRIVATE_KEY" | docker exec -i "${WIREGUARD_CONTAINER}" wg pubkey)
fi
PRESHARED_KEY=$($WG_CMD genpsk)

echo "" >> "$SERVER_CONFIG"
echo "# ${client}" >> "$SERVER_CONFIG"
echo "[Peer]" >> "$SERVER_CONFIG"
if [ -n "$client_ip6" ]; then
    echo "AllowedIPs = ${client_ip}/32, ${client_ip6}/128" >> "$SERVER_CONFIG"
else
    echo "AllowedIPs = ${client_ip}/32" >> "$SERVER_CONFIG"
fi
echo "PresharedKey = ${PRESHARED_KEY}" >> "$SERVER_CONFIG"
echo "PublicKey = ${PUBLIC_KEY}" >> "$SERVER_CONFIG"

echo "[Interface]" > "${client}.conf"
if [ -n "$client_ip6" ]; then
    echo "Address = ${client_ip}/32, ${client_ip6}/128" >> "${client}.conf"
else
    echo "Address = ${client_ip}/32" >> "${client}.conf"
fi
echo "DNS = ${SERVER_ADDRESS}" >> "${client}.conf"
echo "PrivateKey = ${PRIVATE_KEY}" >> "${client}.conf"
echo "" >> "${client}.conf"
echo "[Peer]" >> "${client}.conf"
echo "AllowedIPs = ${AllowedIPs}" >> "${client}.conf"
echo "Endpoint = SERVER_IP_OR_HOSTNAME:${SERVER_PORT}" >> "${client}.conf"
echo "PersistentKeepalive = 25" >> "${client}.conf"
echo "PresharedKey = ${PRESHARED_KEY}" >> "${client}.conf"
echo "PublicKey = ${SERVER_PUBLIC_KEY}" >> "${client}.conf"

chmod 600 "${client}.conf"

echo
echo "Client config created: ${client}.conf"
echo

echo "Reloading WireGuard configuration..."
if $WG_CMD syncconf "$WIREGUARD_INTERFACE" "$SERVER_CONFIG" 2>/dev/null; then
    echo "Configuration reloaded successfully"
else
    if [ "$WG_CMD" != "wg" ]; then
        echo "Note: Run 'docker exec ${WIREGUARD_CONTAINER} wg-quick down $WIREGUARD_INTERFACE && docker exec ${WIREGUARD_CONTAINER} wg-quick up $WIREGUARD_INTERFACE' to apply changes"
    else
        echo "Note: Run 'wg-quick down $WIREGUARD_INTERFACE && wg-quick up $WIREGUARD_INTERFACE' to apply changes"
    fi
fi
