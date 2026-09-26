#!/usr/bin/env bash
set -euo pipefail

# ---------- config ----------
BASE_IMAGE="dunglas/frankenphp"
IMAGE="arifnd/frala"
TAG_FILE="tags.txt"
PLATFORMS="linux/amd64,linux/arm64"

# Single source of truth for the moving-alias tags.
# Bump this one line each PHP release:
LATEST_PHP="php8.5"
declare -A TAG_ALIASES=(["$LATEST_PHP"]="latest" ["${LATEST_PHP}-alpine"]="alpine")

TARGET_TAG="${1:-${TARGET_TAG:-all}}"
[[ -z "$TARGET_TAG" ]] && TARGET_TAG="all"

# ---------- helpers ----------
trim() {
    local s=$1
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "❌ Missing required command: $1" >&2
        exit 1
    }
}

apply_aliases() {
    local tag=$1 alias
    [[ -n "${TAG_ALIASES[$tag]:-}" ]] || return 0
    for alias in ${TAG_ALIASES[$tag]}; do
        echo "🔖 Applying alias $alias → $tag"
        docker buildx imagetools create -t "${IMAGE}:${alias}" "${IMAGE}:${tag}"
    done
}

build_and_push() {
    local tag=$1
    docker buildx build \
        --platform "${PLATFORMS}" \
        --build-arg IMAGE_TAG="$tag" \
        -t "${IMAGE}:${tag}" \
        --push \
        .
}

# ---------- preflight ----------
require_cmd docker
docker info >/dev/null 2>&1 || {
    echo "❌ Docker daemon is not running" >&2
    exit 1
}

# ---------- main ----------
while IFS= read -r TAG || [[ -n "$TAG" ]]; do
    TAG="$(trim "$TAG")"
    [[ -z "$TAG" || "$TAG" =~ ^# ]] && continue

    if [[ "$TARGET_TAG" != "all" && "$TAG" != "$TARGET_TAG" ]]; then
        continue
    fi

    echo "Processing tag: $TAG"

    echo "🛠️ Building image for tag $TAG ($PLATFORMS)..."
    if build_and_push "$TAG"; then
        apply_aliases "$TAG"
    else
        echo "⚠️ Build failed for tag $TAG. Keeping old digest if any."
    fi
done < "$TAG_FILE"
