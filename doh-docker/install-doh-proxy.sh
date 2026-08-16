#!/bin/sh
set -e

readonly BINARY_PATH="/usr/local/bin/doh-proxy"

[ -n "$DOH_PROXY_VERSION" ] || {
    echo "Error: DOH_PROXY_VERSION is not set" >&2
    exit 1
}

# Check architecture
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) ARCH_SUFFIX="x86_64" ;;
    aarch64) ARCH_SUFFIX="aarch64" ;;
    armv7l|armhf)
        echo "Error: 32-bit ARM ($ARCH) is not supported. doh-server only provides x86_64 and aarch64 builds." >&2
        echo "Use 64-bit Raspberry Pi OS (aarch64) instead." >&2
        exit 1
        ;;
    *)
        echo "Error: Unsupported architecture: $ARCH" >&2
        exit 1
        ;;
esac

apk add --no-cache --virtual .build-deps bzip2 tar

DOWNLOAD_URL="https://github.com/DNSCrypt/doh-server/releases/download/${DOH_PROXY_VERSION}/doh-proxy_${DOH_PROXY_VERSION}_linux-${ARCH_SUFFIX}.tar.bz2"
EXTRACT_DIR=$(mktemp -d)
trap 'rm -rf "$EXTRACT_DIR"' EXIT

if ! curl -fL -o "$EXTRACT_DIR/doh-proxy.tar.bz2" "$DOWNLOAD_URL"; then
    echo "Error: failed to download doh-proxy ${DOH_PROXY_VERSION}" >&2
    echo "Error: URL was ${DOWNLOAD_URL}" >&2
    exit 1
fi

if ! tar -xjf "$EXTRACT_DIR/doh-proxy.tar.bz2" -C "$EXTRACT_DIR"; then
    echo "Error: failed to extract the doh-proxy ${DOH_PROXY_VERSION} archive" >&2
    exit 1
fi

[ -f "$EXTRACT_DIR/doh-proxy/doh-proxy" ] || {
    echo "Error: no doh-proxy binary inside the archive (upstream layout changed?)" >&2
    exit 1
}

mv "$EXTRACT_DIR/doh-proxy/doh-proxy" "$BINARY_PATH"
chmod +x "$BINARY_PATH"

apk del .build-deps

echo "Installed doh-proxy ${DOH_PROXY_VERSION} (${ARCH_SUFFIX})"
