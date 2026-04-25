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

echo "Flushing previous Pi4-Docker nftables tables..."
nft delete table inet pi4d_filter 2>/dev/null || true
nft delete table inet pi4d_nat 2>/dev/null || true

# Do not "systemctl restart nftables" here: on Debian/RPI OS the unit's stop step runs a full
# ruleset flush, which removes Docker's DOCKER chain / DOCKER-FORWARD. Load with nft -f only.
echo "Loading nftables rules..."
if ! nft -f "$TARGET_CONF"; then
    echo "Error: nft -f $TARGET_CONF failed" >&2
    exit 1
fi

echo "Firewall rules applied successfully"
