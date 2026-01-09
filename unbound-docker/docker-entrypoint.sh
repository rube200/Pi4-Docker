#!/bin/sh
set -e

ROOT_KEY="/var/lib/unbound/root.key"

if [ ! -f "$ROOT_KEY" ] || [ $(find "$ROOT_KEY" -mtime +180 2>/dev/null | wc -l) -gt 0 ]; then
    mkdir -p /var/lib/unbound
    sleep 2
    unbound-anchor -a "$ROOT_KEY" >/dev/null 2>&1 || true
    
    chown unbound:unbound "$ROOT_KEY" 2>/dev/null || true
    chmod 644 "$ROOT_KEY" 2>/dev/null || true
fi

if [ ! -f "$ROOT_KEY" ]; then
    echo "Error: root.key does not exist. Cannot start unbound."
    exit 1
fi

echo "Starting unbound..."
exec "$@"
