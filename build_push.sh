#!/usr/bin/env bash
set -euo pipefail

BASE_IMAGE="dunglas/frankenphp"
IMAGE="arifnd/frala"
TAG_FILE="tags.txt"

TARGET_TAG="${1:-${TARGET_TAG:-all}}"
[[ -z "$TARGET_TAG" ]] && TARGET_TAG="all"

while IFS= read -r TAG || [[ -n "$TAG" ]]; do
    # strip leading/trailing whitespace
    TAG="${TAG#"${TAG%%[![:space:]]*}"}"
    TAG="${TAG%"${TAG##*[![:space:]]}"}"
  
    [[ -z "$TAG" || "$TAG" =~ ^# ]] && continue

    if [[ "$TARGET_TAG" != "all" && "$TAG" != "$TARGET_TAG" ]]; then
        continue
    fi

    echo "Processing tag: $TAG"

    echo "🛠️ Building image for tag $TAG..."
    if docker build --build-arg IMAGE_TAG="$TAG" -t "${IMAGE}:${TAG}" .; then
        echo "⬆️ Push image for tag $TAG."
        docker push "${IMAGE}:${TAG}"
    else
        echo "⚠️ Build failed for tag $TAG. Keeping old digest if any."
    fi
done < "$TAG_FILE"
