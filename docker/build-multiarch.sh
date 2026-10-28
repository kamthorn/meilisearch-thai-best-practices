#!/usr/bin/env bash
# ==============================================================================
# Build & Push Multi-Arch (amd64 + arm64) Custom Meilisearch Image
# ==============================================================================
# Usage:
#   IMAGE_REPO=docker.io/kamthorn/meilisearch TAG=v1.56.0 ./docker/build-multiarch.sh
# ==============================================================================
set -euo pipefail

IMAGE_REPO="${IMAGE_REPO:-docker.io/kamthorn/meilisearch}"
TAG="${TAG:-v1.56.0}"
DOCKERFILE_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Building ${IMAGE_REPO}:${TAG} (amd64 + arm64)..."

docker build --platform linux/amd64 -t "${IMAGE_REPO}:${TAG}-amd64" "${DOCKERFILE_DIR}"
docker build --platform linux/arm64 -t "${IMAGE_REPO}:${TAG}-arm64" "${DOCKERFILE_DIR}"

docker push "${IMAGE_REPO}:${TAG}-amd64"
docker push "${IMAGE_REPO}:${TAG}-arm64"

for ALIAS in "${TAG}" "v1.56" "v1" "latest"; do
    docker buildx imagetools create \
        -t "${IMAGE_REPO}:${ALIAS}" \
        "${IMAGE_REPO}:${TAG}-amd64" \
        "${IMAGE_REPO}:${TAG}-arm64"
done

echo "Published multi-arch manifest for ${IMAGE_REPO}:${TAG}"
