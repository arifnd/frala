#!/usr/bin/env bash
set -euo pipefail

BASE_IMAGE="dunglas/frankenphp"
IMAGE="arifnd/frala"
TAG_FILE="tags.txt"
DIGESTS_FILE="digests.txt"

TARGET_TAG="${1:-${TARGET_TAG:-all}}"
[[ -z "$TARGET_TAG" ]] && TARGET_TAG="all"

declare -A LOCAL_DIGESTS=()

# Load existing digests
if [[ -f "$DIGESTS_FILE" ]]; then
    while read -r tag digest; do
        [[ -z "$tag" || "$tag" =~ ^# ]] && continue
        LOCAL_DIGESTS["$tag"]="$digest"
    done < "$DIGESTS_FILE"
fi

changed=0

# Truncate digests file to avoid duplicates on re-run
> "$DIGESTS_FILE"

while IFS= read -r TAG || [[ -n "$TAG" ]]; do
    TAG="${TAG#"${TAG%%[![:space:]]*}"}"
    TAG="${TAG%"${TAG##*[![:space:]]}"}"
    [[ -z "$TAG" || "$TAG" =~ ^# ]] && continue

    if [[ "$TARGET_TAG" != "all" && "$TAG" != "$TARGET_TAG" ]]; then
        if [[ -n "${LOCAL_DIGESTS[$TAG]:-}" ]]; then
            echo "$TAG ${LOCAL_DIGESTS[$TAG]}" >> "$DIGESTS_FILE"
        fi
        continue
    fi

    echo "==============================="
    echo " Processing tag: $TAG"
    echo "==============================="

    # Fetch digest
    set +e
    REMOTE_DIGEST=$(docker buildx imagetools inspect "${BASE_IMAGE}:${TAG}" 2>/dev/null \
        | grep -m1 '^Digest:' \
        | awk '{print $2}')
    fetch_status=$?
    set -e

    if [[ $fetch_status -ne 0 || -z "$REMOTE_DIGEST" ]]; then
        echo "⚠️ Cannot fetch remote digest for ${BASE_IMAGE}:${TAG}. Keeping old."
        if [[ -n "${LOCAL_DIGESTS[$TAG]:-}" ]]; then
            echo "$TAG ${LOCAL_DIGESTS[$TAG]}" >> "$DIGESTS_FILE"
        fi
        continue
    fi

    OLD_DIGEST="${LOCAL_DIGESTS[$TAG]:-<none>}"

    echo "Stored digest: $OLD_DIGEST"
    echo "Remote digest: $REMOTE_DIGEST"

    if [[ "${LOCAL_DIGESTS[$TAG]:-}" != "$REMOTE_DIGEST" ]]; then
        echo "🛠️ Digest changed → building image for $TAG"

        # -------------------------------------------
        # SAFE BUILD SECTION (does not stop the script)
        # -------------------------------------------
        set +e
        docker build --build-arg IMAGE_TAG="$TAG" -t "${IMAGE}:${TAG}" .
        build_status=$?
        set -e

        if [[ $build_status -eq 0 ]]; then
            echo "⬆️ Push image for tag $TAG"

            set +e
            docker push "${IMAGE}:${TAG}"
            push_status=$?
            set -e

            if [[ $push_status -eq 0 ]]; then
                echo "$TAG $REMOTE_DIGEST" >> "$DIGESTS_FILE"
                echo "✅ Digest updated for tag $TAG"
                changed=1
            else
                echo "⚠️ Push failed for $TAG. Keeping old digest."
                echo "$TAG ${LOCAL_DIGESTS[$TAG]}" >> "$DIGESTS_FILE"
            fi

        else
            echo "⚠️ Build failed for $TAG. Keeping old digest."
            echo "$TAG ${LOCAL_DIGESTS[$TAG]}" >> "$DIGESTS_FILE"
        fi

    else
        echo "ℹ️ Digest unchanged. Keeping old digest."
        echo "$TAG ${LOCAL_DIGESTS[$TAG]}" >> "$DIGESTS_FILE"
    fi

done < "$TAG_FILE"

if [[ "$changed" -eq 0 ]]; then
    echo "No digest changes detected."
else
    echo "Digest file updated with changes."
fi
