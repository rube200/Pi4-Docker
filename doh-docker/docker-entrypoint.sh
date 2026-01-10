#!/bin/sh
set -e

#Check architecture
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) ARCH_SUFFIX="x86_64" ;;
    aarch64) ARCH_SUFFIX="aarch64" ;;
    *) echo "Error: Unsupported architecture: $ARCH" && exit 1 ;;
esac

[ -z "$SERVER_HOSTNAME" ] && echo "Error: SERVER_HOSTNAME is not set and no config file found" && exit 1

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
GITHUB_API_RESPONSE=$(curl -sf https://api.github.com/repos/DNSCrypt/doh-server/releases/latest 2>&1)
GITHUB_API_EXIT_CODE=$?
if [ $GITHUB_API_EXIT_CODE -ne 0 ]; then
    echo "Error: Failed to fetch latest version from GitHub API (exit code: $GITHUB_API_EXIT_CODE)"
    echo "Error: Response: $GITHUB_API_RESPONSE"
    LATEST_VERSION=""
else
    LATEST_VERSION=$(echo "$GITHUB_API_RESPONSE" | jq -r '.tag_name' | sed 's/^v//' 2>&1)
    JQ_EXIT_CODE=$?
    if [ $JQ_EXIT_CODE -ne 0 ] || [ -z "$LATEST_VERSION" ] || [ "$LATEST_VERSION" = "null" ]; then
        LATEST_VERSION=""
    fi
fi

if [ -n "$LATEST_VERSION" ] && [ "$CURRENT_VERSION" != "$LATEST_VERSION" ]; then
    DOWNLOAD_URL="https://github.com/DNSCrypt/doh-server/releases/download/${LATEST_VERSION}/doh-proxy_${LATEST_VERSION}_linux-${ARCH_SUFFIX}.tar.bz2"
    DOWNLOAD_OUTPUT=$(curl -fL -o /tmp/doh-proxy.tar.bz2 "$DOWNLOAD_URL" 2>&1)
    DOWNLOAD_EXIT_CODE=$?
    if [ $DOWNLOAD_EXIT_CODE -eq 0 ]; then
        EXTRACT_DIR=$(mktemp -d)
        tar -xjf /tmp/doh-proxy.tar.bz2 -C "$EXTRACT_DIR" 2>/dev/null
        mv "$EXTRACT_DIR/doh-proxy/doh-proxy" "$BINARY_PATH" 2>/dev/null
        chmod +x "$BINARY_PATH"
        rm -rf "$EXTRACT_DIR" /tmp/doh-proxy.tar.bz2
    else
        echo "Error: Download failed (exit code: $DOWNLOAD_EXIT_CODE)"
        echo "Error: Download output: $DOWNLOAD_OUTPUT"
    fi
fi

if [ ! -f "$BINARY_PATH" ]; then
    echo "Error: Could not fetch latest version and no binary available"
    exit 1
fi

DOH_PATH_PREFIX="${DOH_PATH_PREFIX:-consulta-dns}"
DOH_PUBLIC_PORT="${DOH_PUBLIC_PORT:-440}"
DOH_UPSTREAM_DNS="${DOH_UPSTREAM_DNS:-pihole:53}"

echo "Starting doh-server..."
exec "$BINARY_PATH" \
    -O \
    -H "$SERVER_HOSTNAME" \
    -l "[::]:3000" \
    -p "$DOH_PATH_PREFIX" \
    -u "$DOH_UPSTREAM_DNS" \
    -j "$DOH_PUBLIC_PORT" \
    --enable-ecs