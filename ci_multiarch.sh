#!/usr/bin/env bash
set -euo pipefail

# =============================================================
# Native multi-arch CI driver for frala.
#
# Modes:
#   plan                 Decide which tags changed and emit the build matrix.
#   build <tag> <plat>   Build one tag for one platform and push IMAGE:<tag>-<arch>.
#   merge                Assemble multi-arch manifests, aliases, and digests.txt.
#
# The workflow runs each mode in its own job/runner so arm64 builds natively
# (ubuntu-24.04-arm) instead of under QEMU.
# =============================================================

# ---------- config (all env-overridable) ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_IMAGE="${BASE_IMAGE:-dunglas/frankenphp}"
IMAGE="${IMAGE:-arifnd/frala}"
TAG_FILE="${TAG_FILE:-$SCRIPT_DIR/tags.txt}"
DIGESTS_FILE="${DIGESTS_FILE:-$SCRIPT_DIR/digests.txt}"
PLAN_FILE="${PLAN_FILE:-$SCRIPT_DIR/plan.tsv}"

# Runner labels for the native per-platform build jobs.
AMD64_RUNNER="${AMD64_RUNNER:-ubuntu-latest}"
ARM64_RUNNER="${ARM64_RUNNER:-ubuntu-24.04-arm}"

# Single source of truth for the moving-alias tags.
# Bump this one line each PHP release:
LATEST_PHP="${LATEST_PHP:-php8.5}"
declare -A TAG_ALIASES=(["$LATEST_PHP"]="latest" ["${LATEST_PHP}-alpine"]="alpine")

TARGET_TAG="${TARGET_TAG:-all}"
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

require_docker() {
    require_cmd docker
    docker info >/dev/null 2>&1 || {
        echo "❌ Docker daemon is not running" >&2
        exit 1
    }
    docker buildx version >/dev/null 2>&1 || {
        echo "❌ Docker buildx is not available" >&2
        exit 1
    }
}

read_tags() {
    local tag
    while IFS= read -r tag || [[ -n "$tag" ]]; do
        tag="$(trim "$tag")"
        [[ -z "$tag" || "$tag" =~ ^# ]] && continue
        printf '%s\n' "$tag"
    done < "$TAG_FILE"
}

fetch_remote_digest() {
    local tag=$1
    docker buildx imagetools inspect "${BASE_IMAGE}:${tag}" \
        --format '{{.Manifest.Digest}}' 2>/dev/null
}

arch_exists() {
    local tag=$1 arch=$2
    docker buildx imagetools inspect "${IMAGE}:${tag}-${arch}" >/dev/null 2>&1
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

set_output() {
    local key=$1 value=$2
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
    else
        printf '%s=%s\n' "$key" "$value"
    fi
}

declare -A LOCAL_DIGESTS=()
load_digests() {
    LOCAL_DIGESTS=()
    [[ -f "$DIGESTS_FILE" ]] || return 0
    local tag digest
    while read -r tag digest; do
        [[ -z "$tag" || "$tag" =~ ^# ]] && continue
        LOCAL_DIGESTS["$tag"]="$digest"
    done < "$DIGESTS_FILE"
}

# ---------- modes ----------
plan() {
    require_docker
    load_digests

    : > "$PLAN_FILE"

    local -a matrix=()
    local tag remote
    while IFS= read -r tag; do
        # Non-target tags are carried over untouched.
        if [[ "$TARGET_TAG" != "all" && "$tag" != "$TARGET_TAG" ]]; then
            printf 'carried\t%s\t-\t%s\n' "$tag" "${LOCAL_DIGESTS[$tag]:-}" >> "$PLAN_FILE"
            continue
        fi

        if ! remote="$(fetch_remote_digest "$tag")" || [[ -z "$remote" ]]; then
            echo "⚠️ Cannot fetch remote digest for ${BASE_IMAGE}:${tag}; keeping old."
            printf 'carried\t%s\t-\t%s\n' "$tag" "${LOCAL_DIGESTS[$tag]:-}" >> "$PLAN_FILE"
            continue
        fi

        if [[ "${LOCAL_DIGESTS[$tag]:-}" == "$remote" ]]; then
            echo "ℹ️ $tag unchanged ($remote)"
            printf 'carried\t%s\t-\t%s\n' "$tag" "$remote" >> "$PLAN_FILE"
            continue
        fi

        echo "🛠️ $tag changed → scheduling native build ($remote)"
        printf 'changed\t%s\t%s\t%s\n' "$tag" "$remote" "${LOCAL_DIGESTS[$tag]:-}" >> "$PLAN_FILE"
        matrix+=("{\"tag\":\"$tag\",\"platform\":\"linux/amd64\",\"arch\":\"amd64\",\"runner\":\"$AMD64_RUNNER\"}")
        matrix+=("{\"tag\":\"$tag\",\"platform\":\"linux/arm64\",\"arch\":\"arm64\",\"runner\":\"$ARM64_RUNNER\"}")
    done < <(read_tags)

    local joined=""
    if (( ${#matrix[@]} > 0 )); then
        local old_ifs="$IFS"
        IFS=','
        joined="${matrix[*]}"
        IFS="$old_ifs"
    fi

    set_output "matrix" "{\"include\":[${joined}]}"
    if (( ${#matrix[@]} > 0 )); then
        set_output "has_tags" "true"
    else
        set_output "has_tags" "false"
    fi

    echo "📝 Plan: $(( ${#matrix[@]} / 2 )) tag(s) to build; wrote $PLAN_FILE"
}

build() {
    [[ $# -eq 2 ]] || {
        echo "Usage: $0 build <tag> <platform>" >&2
        exit 2
    }
    local tag=$1 platform=$2 arch scope
    arch="${platform##*/}"
    scope="${tag}-${arch}"

    require_docker
    docker buildx inspect --bootstrap >/dev/null 2>&1 || {
        echo "❌ No usable buildx builder" >&2
        exit 1
    }

    local -a cache_args=()
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        cache_args=(
            --cache-from "type=gha,scope=${scope}"
            --cache-to "type=gha,mode=max,scope=${scope}"
        )
    fi

    echo "🛠️ Building ${IMAGE}:${tag}-${arch} for ${platform} (cache scope: ${scope})"
    docker buildx build \
        --platform "$platform" \
        ${cache_args[@]+"${cache_args[@]}"} \
        --build-arg IMAGE_TAG="$tag" \
        -t "${IMAGE}:${tag}-${arch}" \
        --push \
        .
}

merge() {
    require_docker
    [[ -r "$PLAN_FILE" ]] || {
        echo "❌ Plan file not found: $PLAN_FILE" >&2
        exit 1
    }

    declare -a FAILED_TAGS=()
    local tmp
    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' EXIT

    local status tag new old
    while IFS=$'\t' read -r status tag new old || [[ -n "$status" ]]; do
        [[ -z "$status" ]] && continue

        if [[ "$status" == "carried" ]]; then
            if [[ -n "$old" && "$old" != "-" ]]; then
                printf '%s %s\n' "$tag" "$old" >> "$tmp"
            fi
            continue
        fi

        # status == changed: both native builds must exist.
        if ! arch_exists "$tag" amd64 || ! arch_exists "$tag" arm64; then
            echo "⚠️ Missing amd64/arm64 image for $tag; keeping old digest." >&2
            FAILED_TAGS+=("$tag:incomplete")
            if [[ -n "$old" && "$old" != "-" ]]; then
                printf '%s %s\n' "$tag" "$old" >> "$tmp"
            fi
            continue
        fi

        echo "🔗 Assembling multi-arch manifest for ${IMAGE}:${tag}"
        if ! docker buildx imagetools create \
            -t "${IMAGE}:${tag}" \
            "${IMAGE}:${tag}-amd64" \
            "${IMAGE}:${tag}-arm64"; then
            echo "⚠️ Manifest merge failed for $tag; keeping old digest." >&2
            FAILED_TAGS+=("$tag:merge")
            if [[ -n "$old" && "$old" != "-" ]]; then
                printf '%s %s\n' "$tag" "$old" >> "$tmp"
            fi
            continue
        fi

        if ! apply_aliases "$tag"; then
            echo "⚠️ Alias tagging failed for $tag (image itself pushed)" >&2
            FAILED_TAGS+=("$tag:alias")
        fi

        printf '%s %s\n' "$tag" "$new" >> "$tmp"
    done < "$PLAN_FILE"

    mv "$tmp" "$DIGESTS_FILE"

    if (( ${#FAILED_TAGS[@]} > 0 )); then
        echo "❌ Failed tags: ${FAILED_TAGS[*]}" >&2
        exit 1
    fi

    echo "✅ digests.txt updated"
}

# ---------- dispatch ----------
case "${1:-}" in
    plan) plan ;;
    build)
        shift
        build "$@"
        ;;
    merge) merge ;;
    *)
        echo "Usage: $0 {plan | build <tag> <platform> | merge}" >&2
        exit 2
        ;;
esac
