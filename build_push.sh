#!/usr/bin/env bash
set -euo pipefail

# ---------- config (all env-overridable) ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_IMAGE="${BASE_IMAGE:-dunglas/frankenphp}"
IMAGE="${IMAGE:-arifnd/frala}"
TAG_FILE="${TAG_FILE:-$SCRIPT_DIR/tags.txt}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"

# Single source of truth for the moving-alias tags.
# Bump this one line each PHP release:
LATEST_PHP="${LATEST_PHP:-php8.5}"
declare -A TAG_ALIASES=(["$LATEST_PHP"]="latest" ["${LATEST_PHP}-alpine"]="alpine")

# Tag selection: first script argument wins, then TARGET_TAG, then "all".
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

# Verify the toolchain needed for multi-platform builds before any tag runs.
preflight() {
    require_cmd docker
    docker info >/dev/null 2>&1 || {
        echo "❌ Docker daemon is not running" >&2
        exit 1
    }
    docker buildx version >/dev/null 2>&1 || {
        echo "❌ Docker buildx is not available" >&2
        exit 1
    }
    docker buildx inspect --bootstrap >/dev/null 2>&1 || {
        echo "❌ No usable buildx builder" >&2
        exit 1
    }
    [[ -r "$TAG_FILE" ]] || {
        echo "❌ Cannot read tag file: $TAG_FILE" >&2
        exit 1
    }
}

# Yield the trimmed, non-comment tags from TAG_FILE, one per line.
read_tags() {
    local tag
    while IFS= read -r tag || [[ -n "$tag" ]]; do
        tag="$(trim "$tag")"
        [[ -z "$tag" || "$tag" =~ ^# ]] && continue
        printf '%s\n' "$tag"
    done < "$TAG_FILE"
}

apply_aliases() {
    local tag=$1
    local -a aliases
    [[ -n "${TAG_ALIASES[$tag]:-}" ]] || return 0
    read -ra aliases <<< "${TAG_ALIASES[$tag]}"
    local alias
    for alias in "${aliases[@]}"; do
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
preflight

# ---------- main ----------
while IFS= read -r TAG; do
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
done < <(read_tags)
