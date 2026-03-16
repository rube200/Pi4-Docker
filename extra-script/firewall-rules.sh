#!/bin/sh
set -e

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly NFTABLES_CONF="${SCRIPT_DIR}/nftables.conf"
readonly TARGET_CONF="/etc/nftables.conf"
readonly WIREGUARD_VPN_SUBNET="10.13.13.0/24"

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

echo "Enabling and starting nftables service..."
systemctl enable nftables.service 2>/dev/null || true
systemctl restart nftables.service 2>/dev/null || true

WIREGUARD_GW="${WIREGUARD_GW:-172.28.0.6}"
if ip route get "$WIREGUARD_GW" >/dev/null 2>&1; then
    ip route replace "$WIREGUARD_VPN_SUBNET" via "$WIREGUARD_GW" 2>/dev/null || \
    ip route add "$WIREGUARD_VPN_SUBNET" via "$WIREGUARD_GW" 2>/dev/null || true
fi

echo "Firewall rules applied successfully"
