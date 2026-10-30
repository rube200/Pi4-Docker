#!/bin/sh
set -e

readonly BINARY_PATH="/usr/local/bin/doh-proxy"

if [ -z "$DOH_PROXY_VERSION" ]; then
    echo "Error: [doh-install] DOH_PROXY_VERSION is not set" >&2
    exit 1
fi

arch=$(uname -m)
case "$arch" in
    aarch64)
        expected_sha256=$DOH_PROXY_SHA256_AARCH64
        ;;
    x86_64)
        expected_sha256=$DOH_PROXY_SHA256_X86_64
        ;;
    armv6l|armv7l)
        echo "Error: [doh-install] 32-bit ARM (${arch}) is not supported; doh-server only provides x86_64 and aarch64 builds" >&2
        exit 1
        ;;
    *)
        echo "Error: [doh-install] unsupported architecture: ${arch}" >&2
        exit 1
        ;;
esac

apk add --no-cache --virtual .build-deps bzip2 tar

download_url="https://github.com/DNSCrypt/doh-server/releases/download/${DOH_PROXY_VERSION}/doh-proxy_${DOH_PROXY_VERSION}_linux-${arch}.tar.bz2"
extract_dir=$(mktemp -d)
trap 'rm -rf "$extract_dir"' EXIT

if ! curl -fL -o "${extract_dir}/doh-proxy.tar.bz2" "$download_url"; then
    echo "Error: [doh-install] failed to download doh-proxy ${DOH_PROXY_VERSION}" >&2
    echo "  URL was ${download_url}" >&2
    exit 1
fi

if ! printf '%s  %s\n' "$expected_sha256" "${extract_dir}/doh-proxy.tar.bz2" | sha256sum -c -; then
    echo "Error: [doh-install] the doh-proxy ${DOH_PROXY_VERSION} archive does not match its SHA-256" >&2
    echo "  Expected ${expected_sha256}" >&2
    exit 1
fi

if ! tar -xjf "${extract_dir}/doh-proxy.tar.bz2" -C "$extract_dir"; then
    echo "Error: [doh-install] failed to extract the doh-proxy ${DOH_PROXY_VERSION} archive" >&2
    exit 1
fi

if [ ! -f "${extract_dir}/doh-proxy/doh-proxy" ]; then
    echo "Error: [doh-install] no doh-proxy binary inside the archive" >&2
    exit 1
fi

mv "${extract_dir}/doh-proxy/doh-proxy" "$BINARY_PATH"
chmod 755 "$BINARY_PATH"

apk del .build-deps

echo "[doh-install] Installed doh-proxy ${DOH_PROXY_VERSION} (${arch})"
