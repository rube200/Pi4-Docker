#!/bin/sh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NFTABLES_CONF="$SCRIPT_DIR/nftables.conf"
TARGET_CONF="/etc/nftables.conf"

if [ ! -f "$NFTABLES_CONF" ]; then
    echo "Error: $NFTABLES_CONF not found"
    exit 1
fi

echo "Copying nftables configuration to $TARGET_CONF..."
cp "$NFTABLES_CONF" "$TARGET_CONF"
chmod 644 "$TARGET_CONF"

echo "Loading nftables rules..."
nft -f "$TARGET_CONF"

echo "Enabling and starting nftables service..."
systemctl enable nftables.service 2>/dev/null || true
systemctl restart nftables.service 2>/dev/null || true

echo "Firewall rules applied successfully"
