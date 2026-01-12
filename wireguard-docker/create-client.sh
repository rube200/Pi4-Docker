#!/bin/sh
set -e

cd /etc/wireguard
umask 077

WIREGUARD_CONFIG="${WIREGUARD_CONFIG:-wg0.conf}"
SERVER_CONFIG="/etc/wireguard/${WIREGUARD_CONFIG}"
SERVER_HOSTNAME="${SERVER_HOSTNAME:-}"
SERVER_PORT="${WIREGUARD_PORT:-51820}"
WIREGUARD_CONTAINER="${WIREGUARD_CONTAINER:-wireguard}"

if [ ! -r "$SERVER_CONFIG" ]; then
    echo "Error: Server config $SERVER_CONFIG not found"
    exit 1
fi

if command -v wg >/dev/null 2>&1; then
    WG_CMD="wg"
elif docker ps --format '{{.Names}}' | grep -q "^${WIREGUARD_CONTAINER}$"; then
    WG_CMD="docker exec ${WIREGUARD_CONTAINER} wg"
else
    echo "Error: 'wg' command not available and WireGuard container '${WIREGUARD_CONTAINER}' not running"
    exit 1
fi

if [ "$WG_CMD" = "wg" ]; then
    SERVER_PUBLIC_KEY=$(grep "^PrivateKey" "$SERVER_CONFIG" | awk '{print $3}' | wg pubkey)
else
    SERVER_PUBLIC_KEY=$(grep "^PrivateKey" "$SERVER_CONFIG" | awk '{print $3}' | docker exec -i "${WIREGUARD_CONTAINER}" wg pubkey)
fi
if [ -z "$SERVER_PUBLIC_KEY" ]; then
    echo "Error: Could not extract server public key from $SERVER_CONFIG"
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
    echo "Error: Could not determine server address"
    exit 1
fi

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
while [ -z "$client" ] || [ -f "/etc/wireguard/${client}.conf" ]; do
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
    echo "Error: Could not find a valid IP address (next would be ${count}, must be 2-254)"
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
            AllowedIPs="${AllowedIPs}, ${SUBNET6}::/${SUBNET6_MASK}"
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
if [ -n "$SERVER_ADDRESS6" ]; then
    echo "DNS = ${SERVER_ADDRESS}, ${SERVER_ADDRESS6}" >> "${client}.conf"
else
    echo "DNS = ${SERVER_ADDRESS}" >> "${client}.conf"
fi
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
if command -v qrencode >/dev/null 2>&1; then
    echo
    qrencode -t UTF8 < "${client}.conf"
    echo
fi

WIREGUARD_INTERFACE="${WIREGUARD_INTERFACE:-wg0}"
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
