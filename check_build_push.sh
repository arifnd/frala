#!/usr/bin/env bash
set -euo pipefail

BASE_IMAGE="dunglas/frankenphp"
IMAGE="arifnd/frala"
TAG_FILE="tags.txt"
DIGESTS_FILE="digests.txt"

declare -A LOCAL_DIGESTS=()

# Load existing digests
if [[ -f "$DIGESTS_FILE" ]]; then
    while read -r tag digest; do
        [[ -z "$tag" || "$tag" =~ ^# ]] && continue
        LOCAL_DIGESTS["$tag"]="$digest"
    done < "$DIGESTS_FILE"
fi

TMP_DIGESTS_FILE=$(mktemp)
changed=0

while IFS= read -r TAG || [[ -n "$TAG" ]]; do
    TAG="${TAG#"${TAG%%[![:space:]]*}"}"
    TAG="${TAG%"${TAG##*[![:space:]]}"}"
    [[ -z "$TAG" || "$TAG" =~ ^# ]] && continue

    echo "Processing tag: $TAG"

    REMOTE_DIGEST=$(docker buildx imagetools inspect "${BASE_IMAGE}:${TAG}" 2>/dev/null \
        | grep -m1 '^Digest:' \
        | awk '{print $2}')

    if [[ -z "$REMOTE_DIGEST" ]]; then
        echo "⚠️ Could not get digest for ${BASE_IMAGE}:${TAG}, keeping old."
        if [[ -n "${LOCAL_DIGESTS[$TAG]:-}" ]]; then
            echo "$TAG ${LOCAL_DIGESTS[$TAG]}" >> "$TMP_DIGESTS_FILE"
        fi
        continue
    fi

    OLD_DIGEST="${LOCAL_DIGESTS[$TAG]:-}"
    echo "Stored digest: ${OLD_DIGEST:-<none>}"
    echo "Remote digest: $REMOTE_DIGEST"

    if [[ "$OLD_DIGEST" != "$REMOTE_DIGEST" ]]; then
        echo "🛠️ Building image for tag $TAG..."

        if docker build --build-arg IMAGE_TAG="$TAG" -t "${IMAGE}:${TAG}" .; then
            echo "⬆️ Push image for tag $TAG."
            docker push "${IMAGE}:${TAG}"

            echo "✅ Digest changed or missing for tag $TAG"
            changed=1
        else
            echo "⚠️ Build failed for tag $TAG. Keeping old digest if any."
        fi
    else
        echo "ℹ️ Digest unchanged for tag $TAG"
    fi

    echo "$TAG $REMOTE_DIGEST" >> "$TMP_DIGESTS_FILE"
done < "$TAG_FILE"

mv "$TMP_DIGESTS_FILE" "$DIGESTS_FILE"

if [[ "$changed" -eq 0 ]]; then
    echo "No digest changes detected."
else
    echo "Digest file updated with changes."
fi
