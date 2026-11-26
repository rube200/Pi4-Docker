#!/bin/sh
set -e

readonly DEPLOY_BRANCH="master"
readonly DEPLOYED_FILE=".git/pi4-docker-deployed"

cd "$(dirname "$0")/.."

if ! command -v git >/dev/null 2>&1; then
    echo "Error: [update] git is not installed" >&2
    exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "Error: [update] docker is not installed" >&2
    exit 1
fi

unsafe_path=$(find "$PWD" \( ! -user root -o ! -type l -perm /go+w \) -print -quit)
if [ -n "$unsafe_path" ]; then
    echo "Error: [update] ${unsafe_path} can be changed by users other than root" >&2
    echo "  Fix the checkout with: sudo chown -R root:root ${PWD} && sudo chmod -R go-w ${PWD}" >&2
    exit 1
fi

if ! branch=$(git branch --show-current); then
    echo "Error: [update] failed to read the checkout" >&2
    exit 1
fi

if [ "$branch" != "$DEPLOY_BRANCH" ]; then
    echo "Note: [update] the checkout is not on ${DEPLOY_BRANCH}, skipping the update" >&2
    echo "  Switch back to ${DEPLOY_BRANCH} to resume updates" >&2
    exit 0
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "Note: [update] the checkout has local changes, skipping the update" >&2
    echo "  Commit, stash or discard them to resume updates" >&2
    exit 0
fi

echo "[update] Fetching updates..."
if ! timeout 60 git -c core.hooksPath=/dev/null fetch --quiet; then
    echo "Error: [update] failed to fetch updates" >&2
    echo "  The next run retries" >&2
    exit 1
fi

if ! upstream=$(git rev-parse '@{upstream}' 2>/dev/null); then
    echo "Error: [update] ${DEPLOY_BRANCH} has no upstream branch" >&2
    echo "  Set it with: git branch --set-upstream-to=origin/${DEPLOY_BRANCH}" >&2
    exit 1
fi

deployed=
if [ -f "$DEPLOYED_FILE" ]; then
    deployed=$(cat "$DEPLOYED_FILE")
fi

case "$deployed" in
    *[!0-9a-f]*) deployed= ;;
esac

if [ "$upstream" = "$deployed" ]; then
    echo "[update] Already up to date"
    exit 0
fi

changes_since=$deployed
if [ -z "$changes_since" ]; then
    changes_since=$(git rev-parse HEAD)
fi

version=$(git rev-parse --short "$upstream")

if ! git merge-base --is-ancestor HEAD "$upstream"; then
    echo "Error: [update] failed to fast-forward to ${version}" >&2
    echo "  The checkout has local commits, or the upstream history was rewritten" >&2
    exit 1
fi

echo "[update] Updating to ${version}..."
git -c core.hooksPath=/dev/null merge --ff-only --quiet "$upstream"

if ! git diff --quiet "$changes_since" HEAD -- host-scripts/firewall-rules.sh host-scripts/nftables.conf; then
    echo "[update] Firewall changed, applying it..."
    if ! sh host-scripts/firewall-rules.sh; then
        echo "Error: [update] failed to apply the firewall" >&2
        echo "  The next run retries" >&2
        exit 1
    fi
fi

echo "[update] Rebuilding changed images and recreating their containers..."
old_images=$(docker compose images -q | sort -u)
if ! docker compose up -d --build --remove-orphans; then
    echo "Error: [update] failed to rebuild or recreate the containers" >&2
    echo "  The next run retries" >&2
    exit 1
fi

if ! git diff --quiet "$changes_since" HEAD -- 'services-docker*'; then
    echo "[update] A systemd unit changed, reloading systemd..."
    if ! systemctl daemon-reload; then
        echo "Error: [update] failed to reload systemd" >&2
        echo "  The next run retries" >&2
        exit 1
    fi
fi

git rev-parse HEAD >"$DEPLOYED_FILE"

new_images=$(docker compose images -q | sort -u)
for image in $old_images; do
    if ! printf '%s\n' "$new_images" | grep -qxF "$image"; then
        if ! docker image rm "$image" >/dev/null; then
            echo "Warning: [update] failed to remove the old image ${image}" >&2
        fi
    fi
done

echo "[update] Deployed ${version}"
