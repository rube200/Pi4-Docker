#!/bin/sh
set -e

#Check architecture
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) ARCH_SUFFIX="x86_64" ;;
    aarch64) ARCH_SUFFIX="aarch64" ;;
    *) echo "Error: Unsupported architecture: $ARCH" && exit 1 ;;
esac

#Retrieve and verify DOH_HOSTNAME
if [ -z "$DOH_HOSTNAME" ]; then
    [ -f "/etc/doh-server/hostname" ] && DOH_HOSTNAME=$(cat /etc/doh-server/hostname | tr -d '\n\r ')
fi
[ -z "$DOH_HOSTNAME" ] && echo "Error: DOH_HOSTNAME is not set and no config file found" && exit 1

#Wait for DNS to be ready (to resolve github.com for API calls)
echo "Waiting for DNS to be ready..."
ATTEMPT=0
MAX_ATTEMPTS=30
while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
    if getent hosts github.com >/dev/null 2>&1; then
        break
    fi
    ATTEMPT=$((ATTEMPT + 1))
    [ $ATTEMPT -lt $MAX_ATTEMPTS ] && sleep 2
done

if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
    echo "Error: DNS not available after $MAX_ATTEMPTS attempts"
    exit 1
fi

#Retrieve current binary version
BINARY_PATH="/usr/local/bin/doh-proxy"
CURRENT_VERSION=""
if [ -f "$BINARY_PATH" ] && [ -x "$BINARY_PATH" ]; then
    CURRENT_VERSION=$($BINARY_PATH --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
fi

#Check if binary is up to date or download latest version
LATEST_VERSION=$(curl -sf https://api.github.com/repos/DNSCrypt/doh-server/releases/latest | jq -r '.tag_name' | sed 's/^v//' || echo "")
if [ -n "$LATEST_VERSION" ] && [ "$CURRENT_VERSION" != "$LATEST_VERSION" ]; then
    echo "Downloading doh-proxy version $LATEST_VERSION..."
    curl -sfL -o /tmp/doh-proxy.tar.bz2 "https://github.com/DNSCrypt/doh-server/releases/download/${LATEST_VERSION}/doh-proxy_${LATEST_VERSION}_linux-${ARCH_SUFFIX}.tar.bz2"
    if [ $? -eq 0 ] && [ -f /tmp/doh-proxy.tar.bz2 ]; then
        EXTRACT_DIR=$(mktemp -d)
        tar -xjf /tmp/doh-proxy.tar.bz2 -C "$EXTRACT_DIR" 2>/dev/null
        mv "$EXTRACT_DIR"/doh-proxy/doh-proxy "$BINARY_PATH" 2>/dev/null
        chmod +x "$BINARY_PATH"
        rm -rf "$EXTRACT_DIR" /tmp/doh-proxy.tar.bz2
    else
        echo "Error: Failed to download binary"
    fi
fi

if [ ! -f "$BINARY_PATH" ]; then
    echo "Error: Could not fetch latest version and no binary available"
    exit 1
fi

DOH_PATH_PREFIX="${DOH_PATH_PREFIX:-query-dns}"
DOH_PUBLIC_PORT="${DOH_PUBLIC_PORT:-443}"
DOH_UPSTREAM_DNS="${DOH_UPSTREAM_DNS:-pihole:53}"

echo "Starting doh-server (IPv4 and IPv6)..."
"$BINARY_PATH" \
    -O \
    -H "$DOH_HOSTNAME" \
    -l "0.0.0.0:3000" \
    -p "$DOH_PATH_PREFIX" \
    -u "$DOH_UPSTREAM_DNS" \
    -j "$DOH_PUBLIC_PORT" \
    --enable-ecs &
PID_IPV4=$!

"$BINARY_PATH" \
    -O \
    -H "$DOH_HOSTNAME" \
    -l "[::]:3000" \
    -p "$DOH_PATH_PREFIX" \
    -u "$DOH_UPSTREAM_DNS" \
    -j "$DOH_PUBLIC_PORT" \
    --enable-ecs &
PID_IPV6=$!

trap "kill $PID_IPV4 $PID_IPV6 2>/dev/null; exit" TERM INT
wait $PID_IPV4 $PID_IPV6