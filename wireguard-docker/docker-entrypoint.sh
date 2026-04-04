#!/bin/sh
set -e

[ -n "$SERVER_HOSTNAME" ] || {
    echo "Error: SERVER_HOSTNAME is not set" >&2
    exit 1
}

readonly WIREGUARD_CONFIG_DIR="/etc/wireguard"
readonly WIREGUARD_FIREWALL_ENV_PATH="${WIREGUARD_CONFIG_DIR}/wg-firewall.env"
readonly WIREGUARD_TEMPLATE_VOLUME_PATH="${WIREGUARD_CONFIG_DIR}/wg0.conf.template"
readonly WIREGUARD_TEMPLATE_IMAGE_PATH="/usr/local/share/wireguard/wg0.conf.template"
readonly CREATE_CLIENT_IMG="/usr/local/bin/create-client.sh"
readonly CREATE_CLIENT_VOL="${WIREGUARD_CONFIG_DIR}/create-client.sh"

if [ ! -r "$WIREGUARD_TEMPLATE_VOLUME_PATH" ] && [ -r "$WIREGUARD_TEMPLATE_IMAGE_PATH" ]; then
    echo "Installing default WireGuard template on volume..."
    cp "$WIREGUARD_TEMPLATE_IMAGE_PATH" "$WIREGUARD_TEMPLATE_VOLUME_PATH"
    chmod 644 "$WIREGUARD_TEMPLATE_VOLUME_PATH"
fi

any_wg_conf_present=no
for wg_conf_path in "$WIREGUARD_CONFIG_DIR"/wg*.conf; do
    [ -f "$wg_conf_path" ] || continue
    any_wg_conf_present=yes
    break
done

if [ "$any_wg_conf_present" = no ]; then
    echo "No wg*.conf in ${WIREGUARD_CONFIG_DIR}; creating wg0.conf from template..."
    cp "$WIREGUARD_TEMPLATE_VOLUME_PATH" "${WIREGUARD_CONFIG_DIR}/wg0.conf"
    chmod 600 "${WIREGUARD_CONFIG_DIR}/wg0.conf"
fi

if [ -r "$CREATE_CLIENT_IMG" ] && [ ! -r "$CREATE_CLIENT_VOL" ]; then
    echo "Installing default create-client.sh on volume..."
    cp "$CREATE_CLIENT_IMG" "$CREATE_CLIENT_VOL"
    chmod 755 "$CREATE_CLIENT_VOL"
    sed -i "s|SERVER_IP_OR_HOSTNAME|${SERVER_HOSTNAME}|g" "$CREATE_CLIENT_VOL"
    chmod +x "$CREATE_CLIENT_VOL"
fi

{
    printf 'SERVER_HOSTNAME=%s\n' "${SERVER_HOSTNAME}"
    printf 'LOCAL_DNS_IP=%s\n' "${LOCAL_DNS_IP}"
    printf 'LOCAL_ALLOWLIST=%s\n' "${LOCAL_ALLOWLIST}"
    printf 'WG_EGRESS_IFACE=%s\n' "${WG_EGRESS_IFACE}"
} >"${WIREGUARD_FIREWALL_ENV_PATH}.new" && mv "${WIREGUARD_FIREWALL_ENV_PATH}.new" "$WIREGUARD_FIREWALL_ENV_PATH"
chmod 644 "$WIREGUARD_FIREWALL_ENV_PATH"

for wg_conf_path in "$WIREGUARD_CONFIG_DIR"/wg*.conf; do
    [ -f "$wg_conf_path" ] || continue
    if grep -q "PRIVATE_KEY_PLACEHOLDER" "$wg_conf_path" 2>/dev/null; then
        echo "Generating WireGuard key for ${wg_conf_path}..."
        generated_private_key=$(wg genkey)
        sed -i "s|PRIVATE_KEY_PLACEHOLDER|${generated_private_key}|g" "$wg_conf_path"
        chmod 600 "$wg_conf_path"
        echo "Public key ($(basename "$wg_conf_path" .conf)): $(printf '%s' "$generated_private_key" | wg pubkey)"
    fi
done

WIREGUARD_INTERFACE_NAMES=$(
    for wg_conf_path in "$WIREGUARD_CONFIG_DIR"/wg*.conf; do
        [ -f "$wg_conf_path" ] || continue
        echo "$(basename "$wg_conf_path" .conf)"
    done | sort -u | tr '\n' ' '
)

trap 'echo "Shutting down WireGuard..."; for started_interface in $WIREGUARD_STARTED_INTERFACES; do wg-quick down "$started_interface" 2>/dev/null || true; done; exit 0' TERM INT

WIREGUARD_STARTED_INTERFACES=""
for interface_name in $WIREGUARD_INTERFACE_NAMES; do
    [ -n "$interface_name" ] || continue
    interface_config_path="${WIREGUARD_CONFIG_DIR}/${interface_name}.conf"
    if [ ! -r "$interface_config_path" ]; then
        echo "Warning: missing ${interface_config_path}, skip" >&2
        continue
    fi

    if wg show "$interface_name" >/dev/null 2>&1; then
        echo "Warning: ${interface_name} already up, taking down first..." >&2
        wg-quick down "$interface_name" 2>/dev/null || true
        sleep 1
    fi

    echo "Starting WireGuard (${interface_name})..."
    if ! wg-quick up "$interface_name"; then
        echo "Error: wg-quick up ${interface_name} failed" >&2
        exit 1
    fi
    WIREGUARD_STARTED_INTERFACES="$interface_name $WIREGUARD_STARTED_INTERFACES"
    wg show "$interface_name"
done

if [ -z "$WIREGUARD_STARTED_INTERFACES" ]; then
    echo "Error: no WireGuard interface was started (check ${WIREGUARD_CONFIG_DIR}/wg*.conf)" >&2
    exit 1
fi

tail -f /dev/null
