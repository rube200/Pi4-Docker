#!/bin/sh
set -e

readonly CHECK_INTERVAL_HOURS=6
readonly DEPLOY_BRANCH="master"
readonly LAST_CHECK_FILE="/run/pi4-docker/apk-checked"
readonly LOCAL_SERVICES="dhcp-relay doh nginx unbound wireguard"

cd "$(dirname "$0")/.."

if ! command -v git >/dev/null 2>&1; then
    echo "Error: [apk-upgrade] git is not installed" >&2
    exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "Error: [apk-upgrade] docker is not installed" >&2
    exit 1
fi

unsafe_path=$(find "$PWD" \( ! -user root -o ! -type l -perm /go+w \) -print -quit)
if [ -n "$unsafe_path" ]; then
    echo "Error: [apk-upgrade] ${unsafe_path} can be changed by users other than root" >&2
    echo "  Fix the checkout with: sudo chown -R root:root ${PWD} && sudo chmod -R go-w ${PWD}" >&2
    exit 1
fi

if ! branch=$(git branch --show-current); then
    echo "Error: [apk-upgrade] failed to read the checkout" >&2
    exit 1
fi

if [ "$branch" != "$DEPLOY_BRANCH" ]; then
    echo "Note: [apk-upgrade] the checkout is not on ${DEPLOY_BRANCH}, skipping the package check" >&2
    echo "  Switch back to ${DEPLOY_BRANCH} to resume package checks" >&2
    exit 0
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "Note: [apk-upgrade] the checkout has local changes, skipping the package check" >&2
    echo "  Commit, stash or discard them to resume package checks" >&2
    exit 0
fi

last_check_hour=0
if [ -f "$LAST_CHECK_FILE" ]; then
    last_check_hour=$(cat "$LAST_CHECK_FILE")
fi

case "$last_check_hour" in
    ''|*[!0-9]*) last_check_hour=0 ;;
esac

current_hour=$(($(date +%s) / 3600))
if [ $((current_hour - last_check_hour)) -lt "$CHECK_INTERVAL_HOURS" ]; then
    echo "[apk-upgrade] Checked less than ${CHECK_INTERVAL_HOURS} hours ago, skipping the package check"
    exit 0
fi

echo "[apk-upgrade] Checking local images for Alpine package upgrades..."
outdated_services=
old_images=
for service in $LOCAL_SERVICES; do
    image="pi4-docker/${service}:local"
    if ! upgrade_plan=$(docker run --rm --pull never --user root --entrypoint apk "$image" upgrade --no-cache --simulate); then
        echo "Error: [apk-upgrade] failed to check ${image}" >&2
        echo "  The next run retries" >&2
        exit 1
    fi

    if printf '%s\n' "$upgrade_plan" | grep -q 'Upgrading'; then
        echo "[apk-upgrade] ${image} has package upgrades"
        outdated_services="${outdated_services:+${outdated_services} }${service}"
        old_images="${old_images} $(docker image inspect -f '{{.Id}}' "$image")"
    fi
done

mkdir -p "$(dirname "$LAST_CHECK_FILE")"
echo "$current_hour" >"$LAST_CHECK_FILE"

if [ -z "$outdated_services" ]; then
    echo "[apk-upgrade] Already up to date"
    exit 0
fi

for service in $outdated_services; do
    echo "[apk-upgrade] Rebuilding ${service} without cache..."
    if ! docker compose build --no-cache "$service"; then
        echo "Error: [apk-upgrade] failed to rebuild ${service}" >&2
        echo "  The next package check retries in ${CHECK_INTERVAL_HOURS} hours" >&2
        exit 1
    fi
done

echo "[apk-upgrade] Recreating the rebuilt containers..."
if ! docker compose up -d --remove-orphans; then
    echo "Error: [apk-upgrade] failed to recreate the rebuilt containers" >&2
    echo "  The next start of services-docker recreates them" >&2
    exit 1
fi

for image in $old_images; do
    if ! docker image rm "$image" >/dev/null; then
        echo "Warning: [apk-upgrade] failed to remove the old image ${image}" >&2
    fi
done

echo "[apk-upgrade] Upgraded ${outdated_services}"
