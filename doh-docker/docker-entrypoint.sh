#!/bin/sh
set -e

readonly BINARY_PATH="/usr/local/bin/doh-proxy"

[ -n "$SERVER_HOSTNAME" ] || {
    echo "Error: SERVER_HOSTNAME is not set and no config file found" >&2
    exit 1
}

[ -x "$BINARY_PATH" ] || {
    echo "Error: $BINARY_PATH is missing or not executable" >&2
    echo "Rebuild the image with: docker compose build doh" >&2
    exit 1
}

DOH_PATH_PREFIX="${DOH_PATH_PREFIX:-consulta-dns}"
DOH_PUBLIC_PORT="${DOH_PUBLIC_PORT:-440}"
DOH_UPSTREAM_DNS="${DOH_UPSTREAM_DNS:-172.28.0.3:53}"

echo "Starting doh-server..."
exec "$BINARY_PATH" \
    -O \
    -H "$SERVER_HOSTNAME" \
    -l "[::]:3000" \
    -p "$DOH_PATH_PREFIX" \
    -j "$DOH_PUBLIC_PORT" \
    -u "$DOH_UPSTREAM_DNS" \
    --enable-ecs