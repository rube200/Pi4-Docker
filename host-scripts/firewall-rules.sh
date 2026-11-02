#!/bin/sh
set -e

readonly DEFAULT_TRUSTED_PREFIX="192.168.0.0/16"
readonly DEFAULT_TRUSTED_PREFIX6="fd00::/8"
readonly TARGET_CONF="/etc/nftables.conf"

env_value() {
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$2" | tail -n1 | tr -d "\"'\r"
}

stage_ruleset() {
    cp "$nftables_conf" "$staged_conf"
    cat >>"$staged_conf" <<EOF

add element inet pi4d_filter trusted_base { $1 }
add element inet pi4d_filter trusted_base6 { $2 }
EOF
}

prefix_is_valid() {
    cp "$nftables_conf" "$staged_conf"
    cat >>"$staged_conf" <<EOF

add element inet pi4d_filter $1 { $2 }
EOF
    nft -c -f "$staged_conf" 2>/dev/null
}

valid_prefixes() {
    _valid=
    for _prefix in $(printf '%s' "$2" | tr ',' ' '); do
        if prefix_is_valid "$1" "$_prefix"; then
            _valid="${_valid:+${_valid},}${_prefix}"
        else
            echo "Warning: [firewall] ignoring invalid prefix ${_prefix}" >&2
        fi
    done
    printf '%s' "$_valid"
}

lan_prefixes() {
    ip -"$1" route show dev "$HOST_LAN_IFACE" 2>/dev/null \
        | awk '$1 != "default" && $1 !~ /^fe80/ && !/ via / {print $1}' | paste -sd, -
}

script_dir=$(dirname "$(readlink -f "$0")")
env_file="$(dirname "$script_dir")/.env"
nftables_conf="${script_dir}/nftables.conf"

if [ -r "$env_file" ]; then
    [ -n "$HOST_LAN_IFACE" ] || HOST_LAN_IFACE=$(env_value HOST_LAN_IFACE "$env_file")
    [ -n "$TRUSTED_PREFIX" ] || TRUSTED_PREFIX=$(env_value TRUSTED_PREFIX "$env_file")
    [ -n "$TRUSTED_PREFIX6" ] || TRUSTED_PREFIX6=$(env_value TRUSTED_PREFIX6 "$env_file")
fi
HOST_LAN_IFACE="${HOST_LAN_IFACE:-eth0}"
TRUSTED_PREFIX="${TRUSTED_PREFIX:-$DEFAULT_TRUSTED_PREFIX}"
TRUSTED_PREFIX6="${TRUSTED_PREFIX6:-$DEFAULT_TRUSTED_PREFIX6}"

if ! command -v nft >/dev/null 2>&1; then
    echo "Error: [firewall] nftables (nft) is not installed" >&2
    exit 1
fi

if [ ! -f "$nftables_conf" ]; then
    echo "Error: [firewall] ${nftables_conf} not found" >&2
    exit 1
fi

staged_conf=$(mktemp)
trap 'rm -f "$staged_conf"' EXIT

echo "[firewall] Validating trusted prefixes..."
trusted=$(valid_prefixes trusted_base "$TRUSTED_PREFIX")
trusted6=$(valid_prefixes trusted_base6 "$TRUSTED_PREFIX6")

if [ -z "$trusted" ]; then
    trusted=$(valid_prefixes trusted_base "$(lan_prefixes 4)")
    [ -n "$trusted" ] || trusted="$DEFAULT_TRUSTED_PREFIX"
    echo "Warning: [firewall] no valid TRUSTED_PREFIX; trusting ${trusted} instead" >&2
fi

if [ -z "$trusted6" ]; then
    trusted6=$(valid_prefixes trusted_base6 "$(lan_prefixes 6)")
    [ -n "$trusted6" ] || trusted6="$DEFAULT_TRUSTED_PREFIX6"
    echo "Warning: [firewall] no valid TRUSTED_PREFIX6; trusting ${trusted6} instead" >&2
fi

echo "[firewall] Trusting IPv4 prefix(es): ${trusted}"
echo "[firewall] Trusting IPv6 prefix(es): ${trusted6}"
stage_ruleset "$trusted" "$trusted6"

echo "[firewall] Validating nftables configuration..."
if ! nft -c -f "$staged_conf"; then
    echo "Error: [firewall] the nftables ruleset is invalid" >&2
    exit 1
fi

echo "[firewall] Copying nftables configuration to ${TARGET_CONF}..."
if [ -f "$TARGET_CONF" ] && [ ! -f "${TARGET_CONF}.bak" ]; then
    cp "$TARGET_CONF" "${TARGET_CONF}.bak"
fi
cp "$staged_conf" "$TARGET_CONF"
chmod 644 "$TARGET_CONF"

echo "[firewall] Loading nftables rules..."
if ! nft -f "$TARGET_CONF"; then
    echo "Error: [firewall] nft -f ${TARGET_CONF} failed" >&2
    exit 1
fi

echo "[firewall] Firewall rules applied successfully"
