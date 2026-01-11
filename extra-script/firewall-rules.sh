#!/bin/sh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RULES_V4="$SCRIPT_DIR/rules.v4"
RULES_V6="$SCRIPT_DIR/rules.v6"
IPTABLES_DIR="/etc/iptables"
TARGET_V4="$IPTABLES_DIR/rules.v4"
TARGET_V6="$IPTABLES_DIR/rules.v6"

if [ ! -f "$RULES_V4" ]; then
    echo "Error: $RULES_V4 not found"
    exit 1
fi

if [ ! -f "$RULES_V6" ]; then
    echo "Error: $RULES_V6 not found"
    exit 1
fi

mkdir -p "$IPTABLES_DIR"

echo "Copying firewall rules to $IPTABLES_DIR..."
cp "$RULES_V4" "$TARGET_V4"
cp "$RULES_V6" "$TARGET_V6"

echo "Restarting netfilter-persistent service..."
systemctl restart netfilter-persistent.service
echo "Firewall rules applied successfully"
