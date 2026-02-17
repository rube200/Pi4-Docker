#!/bin/sh
set -e

if ! command -v nft >/dev/null 2>&1; then
    echo "Error: nftables (nft) is not installed. Install it with: apk add nftables (Alpine) or apt install nftables (Debian/Ubuntu)"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NFTABLES_CONF="$SCRIPT_DIR/nftables.conf"
TARGET_CONF="/etc/nftables.conf"

if [ ! -f "$NFTABLES_CONF" ]; then
    echo "Error: $NFTABLES_CONF not found"
    exit 1
fi

echo "Validating nftables configuration..."
nft -c -f "$NFTABLES_CONF" || { echo "Error: nftables config has syntax errors"; exit 1; }

echo "Copying nftables configuration to $TARGET_CONF..."
if [ -f "$TARGET_CONF" ]; then
    cp "$TARGET_CONF" "${TARGET_CONF}.bak" 2>/dev/null || true
fi
cp "$NFTABLES_CONF" "$TARGET_CONF"
chmod 644 "$TARGET_CONF"

echo "Enabling and starting nftables service..."
systemctl enable nftables.service 2>/dev/null || true
systemctl restart nftables.service 2>/dev/null || true

WIREGUARD_GW="${WIREGUARD_GW:-172.28.0.6}"
if ip route get "$WIREGUARD_GW" >/dev/null 2>&1; then
    ip route replace 10.13.13.0/24 via "$WIREGUARD_GW" 2>/dev/null || \
    ip route add 10.13.13.0/24 via "$WIREGUARD_GW" 2>/dev/null || true
fi

echo "Firewall rules applied successfully"
