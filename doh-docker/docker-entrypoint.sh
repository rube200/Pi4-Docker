#!/bin/sh
set -e

readonly BINARY_PATH="/usr/local/bin/doh-proxy"
readonly DOH_PUBLIC_PORT=8443

start_proxy() {
    "$BINARY_PATH" \
        -H "$HOST_SERVER_HOSTNAME" \
        -l "$1" \
        -p "$DOH_PATH" \
        -j "$DOH_PUBLIC_PORT" \
        -u "$2" \
        --enable-ecs \
        --ecs-prefix-v4 32 \
        --ecs-prefix-v6 128 &
}

if [ -z "$HOST_SERVER_HOSTNAME" ]; then
    echo "Error: [doh] HOST_SERVER_HOSTNAME is not set" >&2
    exit 1
fi

if [ ! -x "$BINARY_PATH" ]; then
    echo "Error: [doh] ${BINARY_PATH} is missing or not executable" >&2
    exit 1
fi

echo "[doh] Starting doh-proxy for IPv4 and IPv6..."
start_proxy "$DOH_LISTEN" "$DOH_UPSTREAM_DNS"
pid=$!
start_proxy "$DOH_LISTEN6" "$DOH_UPSTREAM_DNS6"
pid6=$!

trap 'kill "$pid" "$pid6" 2>/dev/null; exit 0' TERM INT

while kill -0 "$pid" 2>/dev/null && kill -0 "$pid6" 2>/dev/null; do
    sleep 5 &
    wait $!
done

echo "Error: [doh] a doh-proxy process exited" >&2
kill "$pid" "$pid6" 2>/dev/null || true
exit 1
