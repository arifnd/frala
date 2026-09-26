#!/usr/bin/env bash
set -euo pipefail

# ---------- config ----------
BASE_IMAGE="dunglas/frankenphp"
IMAGE="arifnd/frala"
TAG_FILE="tags.txt"
DIGESTS_FILE="digests.txt"
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

fetch_remote_digest() {
    local tag=$1
    docker buildx imagetools inspect "${BASE_IMAGE}:${tag}" \
        --format '{{.Manifest.Digest}}' 2>/dev/null
}

# ---------- preflight ----------
require_cmd docker
docker info >/dev/null 2>&1 || {
    echo "❌ Docker daemon is not running" >&2
    exit 1
}

# ---------- state ----------
declare -A LOCAL_DIGESTS=()

if [[ -f "$DIGESTS_FILE" ]]; then
    while read -r tag digest; do
        [[ -z "$tag" || "$tag" =~ ^# ]] && continue
        LOCAL_DIGESTS["$tag"]="$digest"
    done < "$DIGESTS_FILE"
fi

changed=0

# Write results to a temp file, then swap in atomically.
TMP_DIGESTS="$(mktemp)"
trap 'rm -f "$TMP_DIGESTS"' EXIT

# ---------- main ----------
while IFS= read -r TAG || [[ -n "$TAG" ]]; do
    TAG="$(trim "$TAG")"
    [[ -z "$TAG" || "$TAG" =~ ^# ]] && continue

    # Non-target tags are carried over unchanged.
    if [[ "$TARGET_TAG" != "all" && "$TAG" != "$TARGET_TAG" ]]; then
        [[ -n "${LOCAL_DIGESTS[$TAG]:-}" ]] && echo "$TAG ${LOCAL_DIGESTS[$TAG]}" >> "$TMP_DIGESTS"
        continue
    fi

    echo "==============================="
    echo " Processing tag: $TAG"
    echo "==============================="

    if ! REMOTE_DIGEST="$(fetch_remote_digest "$TAG")" || [[ -z "$REMOTE_DIGEST" ]]; then
        echo "⚠️ Cannot fetch remote digest for ${BASE_IMAGE}:${TAG}. Keeping old."
        [[ -n "${LOCAL_DIGESTS[$TAG]:-}" ]] && echo "$TAG ${LOCAL_DIGESTS[$TAG]}" >> "$TMP_DIGESTS"
        continue
    fi

    echo "Stored digest: ${LOCAL_DIGESTS[$TAG]:-<none>}"
    echo "Remote digest: $REMOTE_DIGEST"

    if [[ "${LOCAL_DIGESTS[$TAG]:-}" == "$REMOTE_DIGEST" ]]; then
        echo "ℹ️ Digest unchanged. Keeping old digest."
        echo "$TAG ${LOCAL_DIGESTS[$TAG]}" >> "$TMP_DIGESTS"
        continue
    fi

    echo "🛠️ Digest changed → building image for $TAG ($PLATFORMS)"

    if ! build_and_push "$TAG"; then
        echo "⚠️ Build/push failed for $TAG. Keeping old digest."
        echo "$TAG ${LOCAL_DIGESTS[$TAG]}" >> "$TMP_DIGESTS"
        continue
    fi

    apply_aliases "$TAG"

    echo "$TAG $REMOTE_DIGEST" >> "$TMP_DIGESTS"
    echo "✅ Digest updated for tag $TAG"
    changed=1
done < "$TAG_FILE"

mv "$TMP_DIGESTS" "$DIGESTS_FILE"

if [[ "$changed" -eq 0 ]]; then
    echo "No digest changes detected."
else
    echo "Digest file updated with changes."
fi
