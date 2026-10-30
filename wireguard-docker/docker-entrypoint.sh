#!/bin/sh
set -e

readonly WG_CONFIG_DIR="/etc/wireguard"
readonly WG_FIREWALL_ENV="${WG_CONFIG_DIR}/wg-firewall.env"
readonly CREATE_CLIENT_IMG="/usr/local/bin/create-client.sh"
readonly CREATE_CLIENT_VOL="${WG_CONFIG_DIR}/create-client.sh"
readonly WG_TEMPLATE_IMG="/usr/local/share/wireguard/wg0.conf.template"
readonly WG_TEMPLATE_VOL="${WG_CONFIG_DIR}/wg0.conf.template"

has_wg_conf() {
    for _path in "$WG_CONFIG_DIR"/wg*.conf; do
        [ -f "$_path" ] && return 0
    done
    return 1
}

stop_wireguard() {
    echo "[wg] Shutting down WireGuard..."
    for _interface in $started_interfaces; do
        wg-quick down "$_interface" 2>/dev/null || true
    done
    exit 0
}

if [ -z "$HOST_SERVER_HOSTNAME" ]; then
    echo "Error: [wg] HOST_SERVER_HOSTNAME is not set" >&2
    exit 1
fi

if [ ! -r "$WG_TEMPLATE_VOL" ] && [ -r "$WG_TEMPLATE_IMG" ]; then
    echo "[wg] Installing default WireGuard template on volume..."
    cp "$WG_TEMPLATE_IMG" "$WG_TEMPLATE_VOL"
    chmod 644 "$WG_TEMPLATE_VOL"
fi

if ! has_wg_conf; then
    echo "[wg] No wg*.conf in ${WG_CONFIG_DIR}; creating wg0.conf from template..."
    cp "$WG_TEMPLATE_VOL" "${WG_CONFIG_DIR}/wg0.conf"
    chmod 600 "${WG_CONFIG_DIR}/wg0.conf"
fi

if ! cmp -s "$CREATE_CLIENT_IMG" "$CREATE_CLIENT_VOL"; then
    echo "[wg] Installing create-client.sh on volume..."
    cp "$CREATE_CLIENT_IMG" "$CREATE_CLIENT_VOL"
    chmod 755 "$CREATE_CLIENT_VOL"
fi

WG_EGRESS_IFACE=$(ip route show default | awk '{print $5; exit}')

cat >"${WG_FIREWALL_ENV}.new" <<EOF
HOST_LAN_IP6='${HOST_LAN_IP6}'
HOST_SERVER_HOSTNAME='${HOST_SERVER_HOSTNAME}'
WG_ALLOWLIST='${WG_ALLOWLIST}'
WG_DNS_IP='${WG_DNS_IP}'
WG_DNS_IP6='${WG_DNS_IP6}'
WG_EGRESS_IFACE='${WG_EGRESS_IFACE:-eth0}'
WG_FULL_ACCESS_MASK='${WG_FULL_ACCESS_MASK}'
WG_NGINX_IP='${WG_NGINX_IP}'
WG_NGINX_IP6='${WG_NGINX_IP6}'
EOF
mv "${WG_FIREWALL_ENV}.new" "$WG_FIREWALL_ENV"
chmod 644 "$WG_FIREWALL_ENV"

for config_path in "$WG_CONFIG_DIR"/wg*.conf; do
    [ -f "$config_path" ] || continue
    if grep -q "PRIVATE_KEY_PLACEHOLDER" "$config_path" 2>/dev/null; then
        echo "[wg] Generating WireGuard key for ${config_path}..."
        generated_private_key=$(wg genkey)
        sed -i "s|PRIVATE_KEY_PLACEHOLDER|${generated_private_key}|g" "$config_path"
        chmod 600 "$config_path"
        echo "[wg] Public key ($(basename "$config_path" .conf)): $(printf '%s' "$generated_private_key" | wg pubkey)"
    fi
done

started_interfaces=

trap stop_wireguard TERM INT

for config_path in "$WG_CONFIG_DIR"/wg*.conf; do
    if [ ! -r "$config_path" ]; then
        if [ -e "$config_path" ]; then
            echo "Warning: [wg] cannot read ${config_path}, skipping" >&2
        fi
        continue
    fi
    interface_name=$(basename "$config_path" .conf)

    if wg show "$interface_name" >/dev/null 2>&1; then
        echo "Warning: [wg] ${interface_name} is already up, taking it down first" >&2
        wg-quick down "$interface_name" 2>/dev/null || true
        sleep 1
    fi

    echo "[wg] Starting WireGuard (${interface_name})..."
    if ! wg-quick up "$interface_name"; then
        echo "Error: [wg] wg-quick up ${interface_name} failed" >&2
        exit 1
    fi
    started_interfaces="$interface_name $started_interfaces"
    wg show "$interface_name"
done

if [ -z "$started_interfaces" ]; then
    echo "Error: [wg] no WireGuard interface was started" >&2
    exit 1
fi

tail -f /dev/null &
wait $!
