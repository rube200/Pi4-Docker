#!/bin/sh
set -e

readonly DEFAULT_WG_PORT=51820
readonly WG_CONFIG_DIR="/etc/wireguard"
readonly WG_FIREWALL_ENV="${WG_CONFIG_DIR}/wg-firewall.env"
readonly WIREGUARD_CONTAINER="wireguard"

wg_run() {
    if [ "$wg_mode" = "local" ]; then
        wg "$@"
    else
        docker exec -i "$WIREGUARD_CONTAINER" wg "$@"
    fi
}

peer_block() {
    cat <<EOF
[Peer]
AllowedIPs = ${client_address}
PresharedKey = ${preshared_key}
PublicKey = ${public_key}
EOF
}

read_choice() {
    _max=$1
    while :; do
        printf '%s' "$2"
        read -r choice || exit 1
        case "$choice" in
            ''|*[!0-9]*) ;;
            *) [ "$choice" -ge 1 ] && [ "$choice" -le "$_max" ] && return 0 ;;
        esac
        echo "Invalid selection: enter a number between 1 and ${_max}"
    done
}

octet_in_use() {
    case "$used_octets" in
        *" $1 "*) return 0 ;;
    esac
    grep -qiF "${subnet6}$(printf '%x' "$1")/128" "$server_config"
}

wg_configs() {
    for _path in wg*.conf; do
        if [ -f "$_path" ]; then
            printf '%s\n' "$_path"
        fi
    done
}

first_free_octet() {
    _candidate=$1
    while [ "$_candidate" -le "$2" ]; do
        if ! octet_in_use "$_candidate"; then
            printf '%s' "$_candidate"
            return 0
        fi
        _candidate=$((_candidate + 1))
    done
    return 1
}

cd "$WG_CONFIG_DIR"
umask 077

if [ ! -r "$WG_FIREWALL_ENV" ]; then
    echo "Error: [wg-client] ${WG_FIREWALL_ENV} not found" >&2
    exit 1
fi
. "$WG_FIREWALL_ENV"

if [ -z "$HOST_SERVER_HOSTNAME" ]; then
    echo "Error: [wg-client] HOST_SERVER_HOSTNAME is not set in ${WG_FIREWALL_ENV}" >&2
    exit 1
fi

if [ -z "$WG_FULL_ACCESS_MASK" ]; then
    echo "Error: [wg-client] WG_FULL_ACCESS_MASK is not set in ${WG_FIREWALL_ENV}" >&2
    exit 1
fi
full_access_last=$(( (1 << (32 - WG_FULL_ACCESS_MASK)) - 1 ))

wg_list=$(wg_configs)
if [ -z "$wg_list" ]; then
    echo "Error: [wg-client] no wg*.conf in ${WG_CONFIG_DIR}" >&2
    exit 1
fi

wg_count=$(printf '%s\n' "$wg_list" | wc -l | tr -d ' \t')
if [ "$wg_count" -eq 1 ]; then
    wireguard_config="$wg_list"
else
    echo "Available WireGuard server configs:"
    index=0
    while IFS= read -r line; do
        index=$((index + 1))
        echo "  ${index}) ${line%.conf}"
    done <<EOF
$wg_list
EOF
    read_choice "$wg_count" "Select interface [1-${wg_count}]: "
    wireguard_config=$(printf '%s' "$wg_list" | sed -n "${choice}p")
fi

wireguard_interface=${wireguard_config%.conf}
server_config="${WG_CONFIG_DIR}/${wireguard_config}"

if [ ! -r "$server_config" ]; then
    echo "Error: [wg-client] ${server_config} not found" >&2
    exit 1
fi

if command -v docker >/dev/null 2>&1 && [ "$(docker inspect -f '{{.State.Running}}' "$WIREGUARD_CONTAINER" 2>/dev/null)" = "true" ]; then
    wg_mode=container
elif wg show "$wireguard_interface" >/dev/null 2>&1; then
    wg_mode=local
else
    echo "Error: [wg-client] ${wireguard_interface} is not up here and container ${WIREGUARD_CONTAINER} is not running" >&2
    exit 1
fi

server_listen_port=$(sed -n 's/^[[:space:]]*ListenPort[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$server_config" | head -n1)
server_port="${server_listen_port:-$DEFAULT_WG_PORT}"

server_public_key=$(sed -n 's/^[[:space:]]*PrivateKey[[:space:]]*=[[:space:]]*//p' "$server_config" | head -n1 | wg_run pubkey) || true
if [ -z "$server_public_key" ]; then
    echo "Error: [wg-client] failed to extract the server public key from ${server_config}" >&2
    exit 1
fi

server_address_cidr=
server_address6_cidr=
for address_token in $(sed -n 's/^[[:space:]]*Address[[:space:]]*=[[:space:]]*//p' "$server_config" | head -n1 | tr ',' ' '); do
    case "$address_token" in
        *:*) [ -n "$server_address6_cidr" ] || server_address6_cidr=$address_token ;;
        *) [ -n "$server_address_cidr" ] || server_address_cidr=$address_token ;;
    esac
done

if [ -z "$server_address_cidr" ] || [ -z "$server_address6_cidr" ]; then
    echo "Error: [wg-client] ${server_config} needs an IPv4 and an IPv6 Address" >&2
    exit 1
fi

server_address=${server_address_cidr%%/*}
server_address6=${server_address6_cidr%%/*}

echo
echo "Server: ${wireguard_config} (interface ${wireguard_interface})"

subnet=$(printf '%s' "$server_address" | cut -d'.' -f1-3)
case "$server_address6" in
    *::*) subnet6=$(printf '%s' "$server_address6" | sed 's/::.*$/::/') ;;
    *) subnet6="$(printf '%s' "$server_address6" | cut -d':' -f1-5)::" ;;
esac

echo
echo "Provide a name for the client:"
while :; do
    printf 'Name: '
    read -r unsanitized_client || exit 1
    client=$(printf '%s' "$unsanitized_client" | sed 's/[^0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-]/_/g')
    case "$client" in
        wg*)
            echo "Invalid name: '${client}' starts with wg, which is reserved for server configs"
            continue
            ;;
    esac
    client_config="${WG_CONFIG_DIR}/${client}.conf"
    [ -n "$client" ] && [ ! -f "$client_config" ] && break
    echo "Invalid name: '${client}' is not usable or already exists"
done

used_octets=" ${server_address##*.} "
max_octet=$full_access_last
while IFS= read -r peer_ip; do
    if [ -n "$peer_ip" ]; then
        last_octet=$(printf '%s' "$peer_ip" | cut -d'.' -f4)
        used_octets="${used_octets}${last_octet} "
        if [ "$last_octet" -le 254 ] && [ "$last_octet" -gt "$max_octet" ]; then
            max_octet=$last_octet
        fi
    fi
done <<EOF
$(sed -n 's/^[[:space:]]*AllowedIPs[[:space:]]*=//p' "$server_config" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
EOF

echo
echo "Choose client access:"
echo "  1) Full access (LAN and Pi)"
echo "  2) Internet only (plus DNS, web)"
read_choice 2 'Access [1-2]: '
case "$choice" in
    1)
        access_label="full access"
        if ! client_octet=$(first_free_octet 2 "$full_access_last"); then
            echo "Error: [wg-client] no free full access address: ${subnet}.2 to ${subnet}.${full_access_last} are all in use" >&2
            exit 1
        fi
        ;;
    2)
        access_label="internet only"
        if ! client_octet=$(first_free_octet "$((max_octet + 1))" 254); then
            echo "Error: [wg-client] no free internet only address up to ${subnet}.254" >&2
            exit 1
        fi
        ;;
esac

client_ip="${subnet}.${client_octet}"
client_ip6="${subnet6}$(printf '%x' "$client_octet")"
client_address="${client_ip}/32, ${client_ip6}/128"
client_dns="${server_address}, ${server_address6}"

echo
echo "Using client IP: ${client_ip}, ${client_ip6} (${access_label})"

private_key=$(wg_run genkey)
public_key=$(printf '%s' "$private_key" | wg_run pubkey)
preshared_key=$(wg_run genpsk)

cat >"$client_config" <<EOF
[Interface]
Address = ${client_address}
DNS = ${client_dns}
PrivateKey = ${private_key}

[Peer]
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${HOST_SERVER_HOSTNAME}:${server_port}
PersistentKeepalive = 25
PresharedKey = ${preshared_key}
PublicKey = ${server_public_key}
EOF

chmod 600 "$client_config"

printf '\n# %s (%s)\n' "$client" "$access_label" >>"$server_config"
peer_block >>"$server_config"

echo
echo "Client config created: ${client_config}"
echo
echo "Reloading WireGuard configuration..."
if peer_block | wg_run addconf "$wireguard_interface" /dev/stdin; then
    echo "Configuration reloaded successfully"
else
    echo "Warning: [wg-client] the running interface was not updated; the peer applies on the next container start" >&2
fi
