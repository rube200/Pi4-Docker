#!/bin/sh
set -e

CONFIG_FILE="/etc/wireguard/${WIREGUARD_CONFIG}"
TEMPLATE_FILE="/etc/wireguard/${WIREGUARD_CONFIG}.template"
DEFAULT_TEMPLATE="/usr/local/share/wireguard/wg0.conf.template"
CREATE_CLIENT_SCRIPT="/etc/wireguard/create-client.sh"
DEFAULT_CREATE_CLIENT_SCRIPT="/usr/local/bin/create-client.sh"

if [ ! -r "$CONFIG_FILE" ]; then
    if [ ! -r "$TEMPLATE_FILE" ] && [ -r "$DEFAULT_TEMPLATE" ]; then
        echo "Copying default template to volume..."
        cp "$DEFAULT_TEMPLATE" "$TEMPLATE_FILE"
        chmod 644 "$TEMPLATE_FILE"
    fi
    
    if [ -r "$TEMPLATE_FILE" ]; then
        echo "Copying template to $CONFIG_FILE..."
        cp "$TEMPLATE_FILE" "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
    else
        echo "Error: $CONFIG_FILE not found and no template available"
        exit 1
    fi
fi

if [ -r "$DEFAULT_CREATE_CLIENT_SCRIPT" ]; then
    if [ ! -r "$CREATE_CLIENT_SCRIPT" ]; then
        echo "Copying create-client.sh to volume..."
        cp "$DEFAULT_CREATE_CLIENT_SCRIPT" "$CREATE_CLIENT_SCRIPT"
    fi

    if grep -q "SERVER_IP_OR_HOSTNAME" "$CREATE_CLIENT_SCRIPT" 2>/dev/null; then
        echo "Replacing SERVER_IP_OR_HOSTNAME with ${SERVER_HOSTNAME}..."
        sed -i "s|SERVER_IP_OR_HOSTNAME|${SERVER_HOSTNAME}|g" "$CREATE_CLIENT_SCRIPT"
    fi
    chmod +x "$CREATE_CLIENT_SCRIPT"
fi

if [ -z "$WIREGUARD_INTERFACE" ]; then
    INTERFACE="${WIREGUARD_CONFIG%.conf}"
else
    INTERFACE="$WIREGUARD_INTERFACE"
fi

if grep -q "PRIVATE_KEY_PLACEHOLDER" "$CONFIG_FILE" 2>/dev/null; then
    echo "Generating WireGuard private key..."
    PRIVATE_KEY=$(wg genkey)
    PUBLIC_KEY=$(echo "$PRIVATE_KEY" | wg pubkey)
    
    sed -i "s|PRIVATE_KEY_PLACEHOLDER|$PRIVATE_KEY|g" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    echo "Private key generated and inserted"
    echo "Public key: $PUBLIC_KEY"
fi

cleanup() {
    echo "Shutting down WireGuard..."
    PIHOLE_IP=$(getent hosts pihole 2>/dev/null | awk '{print $1}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
    if [ -z "$PIHOLE_IP" ]; then
        PIHOLE_IP=$(getent ahosts pihole 2>/dev/null | awk '{print $1}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
    fi
    PIHOLE_IP6=$(getent ahostsv6 pihole 2>/dev/null | awk '{print $1}' | grep -v '^::' | grep -E '^[0-9a-fA-F:]+$' | head -1)
    
    if [ -n "$INTERFACE" ]; then
        if [ -n "$PIHOLE_IP" ]; then
            iptables -t nat -D PREROUTING -i "$INTERFACE" -p udp --dport 53 -j DNAT --to-destination "$PIHOLE_IP:53" 2>/dev/null || true
            iptables -t nat -D PREROUTING -i "$INTERFACE" -p tcp --dport 53 -j DNAT --to-destination "$PIHOLE_IP:53" 2>/dev/null || true
            iptables -D FORWARD -i "$INTERFACE" -d "$PIHOLE_IP" -p udp --dport 53 -j ACCEPT 2>/dev/null || true
            iptables -D FORWARD -i "$INTERFACE" -d "$PIHOLE_IP" -p tcp --dport 53 -j ACCEPT 2>/dev/null || true
        fi
        if [ -n "$PIHOLE_IP6" ]; then
            ip6tables -t nat -D PREROUTING -i "$INTERFACE" -p udp --dport 53 -j DNAT --to-destination "[$PIHOLE_IP6]:53" 2>/dev/null || true
            ip6tables -t nat -D PREROUTING -i "$INTERFACE" -p tcp --dport 53 -j DNAT --to-destination "[$PIHOLE_IP6]:53" 2>/dev/null || true
            ip6tables -D FORWARD -i "$INTERFACE" -d "$PIHOLE_IP6" -p udp --dport 53 -j ACCEPT 2>/dev/null || true
            ip6tables -D FORWARD -i "$INTERFACE" -d "$PIHOLE_IP6" -p tcp --dport 53 -j ACCEPT 2>/dev/null || true
        fi
    fi
    wg-quick down "$INTERFACE" 2>/dev/null || true
    exit 0
}
trap cleanup TERM INT

if wg show "$INTERFACE" >/dev/null 2>&1; then
    echo "Warning: Interface $INTERFACE already exists, bringing it down..."
    wg-quick down "$INTERFACE" 2>/dev/null || true
    sleep 1
fi

CONFIG_BASENAME="${WIREGUARD_CONFIG%.conf}"
if [ "$INTERFACE" = "$CONFIG_BASENAME" ]; then
    WG_CMD="$INTERFACE"
else
    WG_CMD="$CONFIG_FILE"
fi

echo "Starting WireGuard interface $INTERFACE from $CONFIG_FILE..."
if ! wg-quick up "$WG_CMD"; then
    echo "Error: Failed to start WireGuard interface"
    exit 1
fi

PIHOLE_IP=$(getent hosts pihole 2>/dev/null | awk '{print $1}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
if [ -z "$PIHOLE_IP" ]; then
    PIHOLE_IP=$(getent ahosts pihole 2>/dev/null | awk '{print $1}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
fi

PIHOLE_IP6=$(getent ahostsv6 pihole 2>/dev/null | awk '{print $1}' | grep -v '^::' | grep -E '^[0-9a-fA-F:]+$' | head -1)

if [ -n "$PIHOLE_IP" ] || [ -n "$PIHOLE_IP6" ]; then
    if [ -n "$PIHOLE_IP" ]; then
        echo "Setting up IPv4 DNS forwarding to pihole at $PIHOLE_IP..."
        iptables -t nat -A PREROUTING -i "$INTERFACE" -p udp --dport 53 -j DNAT --to-destination "$PIHOLE_IP:53" 2>/dev/null || true
        iptables -t nat -A PREROUTING -i "$INTERFACE" -p tcp --dport 53 -j DNAT --to-destination "$PIHOLE_IP:53" 2>/dev/null || true
        iptables -A FORWARD -i "$INTERFACE" -d "$PIHOLE_IP" -p udp --dport 53 -j ACCEPT 2>/dev/null || true
        iptables -A FORWARD -i "$INTERFACE" -d "$PIHOLE_IP" -p tcp --dport 53 -j ACCEPT 2>/dev/null || true
    fi

    if [ -n "$PIHOLE_IP6" ]; then
        echo "Setting up IPv6 DNS forwarding to pihole at $PIHOLE_IP6..."
        ip6tables -t nat -A PREROUTING -i "$INTERFACE" -p udp --dport 53 -j DNAT --to-destination "[$PIHOLE_IP6]:53" 2>/dev/null || true
        ip6tables -t nat -A PREROUTING -i "$INTERFACE" -p tcp --dport 53 -j DNAT --to-destination "[$PIHOLE_IP6]:53" 2>/dev/null || true
        ip6tables -A FORWARD -i "$INTERFACE" -d "$PIHOLE_IP6" -p udp --dport 53 -j ACCEPT 2>/dev/null || true
        ip6tables -A FORWARD -i "$INTERFACE" -d "$PIHOLE_IP6" -p tcp --dport 53 -j ACCEPT 2>/dev/null || true
    fi
    echo "DNS forwarding configured"
else
    echo "Warning: Could not resolve pihole hostname, DNS forwarding not configured"
fi

echo "WireGuard is running"
wg show "$INTERFACE"
exec tail -f /dev/null