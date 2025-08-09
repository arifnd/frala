#!/usr/bin/env bash
set -euo pipefail

BASE_IMAGE="dunglas/frankenphp"
IMAGE="arifnd/frala"
TAG_FILE="tags.txt"
DIGESTS_FILE="digests.txt"

declare -A LOCAL_DIGESTS=()

# Load saved digests from file
if [[ -f "$DIGESTS_FILE" ]]; then
    while read -r tag digest; do
        [[ -z "$tag" || "$tag" =~ ^# ]] && continue
        LOCAL_DIGESTS["$tag"]="$digest"
    done < "$DIGESTS_FILE"
fi

TMP_DIGESTS_FILE=$(mktemp)

while IFS= read -r TAG || [[ -n "$TAG" ]]; do
    # strip leading/trailing whitespace
    TAG="${TAG#"${TAG%%[![:space:]]*}"}"
    TAG="${TAG%"${TAG##*[![:space:]]}"}"
  
    [[ -z "$TAG" || "$TAG" =~ ^# ]] && continue

    echo "Processing tag: $TAG"

    echo "Pulling image ${BASE_IMAGE}:${TAG}..."
    if ! docker pull "${BASE_IMAGE}:${TAG}"; then
        echo "⚠️ Failed to pull image ${BASE_IMAGE}:${TAG}, skipping..."
        # Keep old digest if any
        if [[ -n "${LOCAL_DIGESTS[$TAG]:-}" ]]; then
            echo "$TAG ${LOCAL_DIGESTS[$TAG]}" >> "$TMP_DIGESTS_FILE"
        fi
        continue
    fi

    # Get digest of pulled image locally (format: repo@sha256:...)
    LOCAL_IMAGE_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "${BASE_IMAGE}:${TAG}" 2>/dev/null || echo "")
    # Extract only sha256 hash portion from "repo@sha256:abcd..."
    REMOTE_DIGEST=$(echo "$LOCAL_IMAGE_DIGEST" | grep -oE 'sha256:[a-f0-9]+')

    if [[ -z "$REMOTE_DIGEST" ]]; then
        echo "⚠️ Could not get digest from local image ${BASE_IMAGE}:${TAG}, skipping build."
        # Keep old digest if any
        if [[ -n "${LOCAL_DIGESTS[$TAG]:-}" ]]; then
            echo "$TAG ${LOCAL_DIGESTS[$TAG]}" >> "$TMP_DIGESTS_FILE"
        fi
        continue
    fi

    OLD_DIGEST="${LOCAL_DIGESTS[$TAG]:-}"

    echo "Stored digest: ${OLD_DIGEST:-<none>}"
    echo "Pulled image digest: $REMOTE_DIGEST"

    if [[ "$OLD_DIGEST" != "$REMOTE_DIGEST" ]]; then
        echo "✅ Digest changed or missing. Building image for tag $TAG..."

        if docker build --build-arg IMAGE_TAG="$TAG" -t "${IMAGE}:${TAG}" .; then
            echo "$TAG $REMOTE_DIGEST" >> "$TMP_DIGESTS_FILE"
        else
            echo "⚠️ Build failed for tag $TAG. Keeping old digest if any."
            [[ -n "$OLD_DIGEST" ]] && echo "$TAG $OLD_DIGEST" >> "$TMP_DIGESTS_FILE"
        fi
    else
        echo "ℹ️ Digest unchanged for tag $TAG. Skipping build."
        echo "$TAG $OLD_DIGEST" >> "$TMP_DIGESTS_FILE"
    fi

done < "$TAG_FILE"

mv "$TMP_DIGESTS_FILE" "$DIGESTS_FILE"
echo "✅ Updated digest file: $DIGESTS_FILE"
