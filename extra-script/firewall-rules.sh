#!/bin/sh
set -e

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly NFTABLES_CONF="${SCRIPT_DIR}/nftables.conf"
readonly TARGET_CONF="/etc/nftables.conf"

if ! command -v nft >/dev/null 2>&1; then
    echo "Error: nftables (nft) is not installed. Install it with: apk add nftables (Alpine) or apt install nftables (Debian/Ubuntu)" >&2
    exit 1
fi

if [ ! -f "$NFTABLES_CONF" ]; then
    echo "Error: $NFTABLES_CONF not found" >&2
    exit 1
fi

echo "Validating nftables configuration..."
nft -c -f "$NFTABLES_CONF" || { echo "Error: nftables config has syntax errors" >&2; exit 1; }

echo "Copying nftables configuration to $TARGET_CONF..."
if [ -f "$TARGET_CONF" ]; then
    cp "$TARGET_CONF" "${TARGET_CONF}.bak" 2>/dev/null || true
fi
cp "$NFTABLES_CONF" "$TARGET_CONF"
chmod 644 "$TARGET_CONF"

echo "Loading nftables rules..."
systemctl enable nftables.service 2>/dev/null || true
if ! systemctl restart nftables.service; then
    echo "Error: systemctl restart nftables.service failed" >&2
    exit 1
fi
if ! systemctl is-active --quiet nftables.service; then
    echo "Error: nftables.service is not active after restart" >&2
    exit 1
fi

echo "Firewall rules applied successfully"
