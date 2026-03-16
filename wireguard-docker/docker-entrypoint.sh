#!/bin/sh
set -e

[ -z "$SERVER_HOSTNAME" ] && echo "Error: SERVER_HOSTNAME is not set" >&2 && exit 1

WIREGUARD_CONFIG="${WIREGUARD_CONFIG:-wg0.conf}"
readonly WG_CONF_DIR="/etc/wireguard"
readonly CONFIG_FILE="${WG_CONF_DIR}/${WIREGUARD_CONFIG}"
readonly TEMPLATE_FILE="${WG_CONF_DIR}/${WIREGUARD_CONFIG}.template"
readonly DEFAULT_TEMPLATE="/usr/local/share/wireguard/wg0.conf.template"
readonly DEFAULT_CREATE_CLIENT_SCRIPT="/usr/local/bin/create-client.sh"
readonly CREATE_CLIENT_SCRIPT="${WG_CONF_DIR}/create-client.sh"
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
        echo "Error: $CONFIG_FILE not found and no template available" >&2
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
    wg-quick down "$INTERFACE" 2>/dev/null || true
    exit 0
}
trap cleanup TERM INT

if wg show "$INTERFACE" >/dev/null 2>&1; then
    echo "Warning: Interface $INTERFACE already exists, bringing it down..." >&2
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
    echo "Error: Failed to start WireGuard interface" >&2
    exit 1
fi

echo "WireGuard is running"
wg show "$INTERFACE"
exec tail -f /dev/null