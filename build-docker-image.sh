#!/usr/bin/env bash
# Build the elk-crossbuild-bookworm Docker image for cross-compiling Sushi.
#
# Usage:
#   ./build-docker-image.sh              # build image
#   ./build-docker-image.sh --no-cache   # rebuild from scratch

set -euo pipefail
export MSYS_NO_PATHCONV=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE="elk-crossbuild-bookworm"

EXTRA_ARGS=("$@")

echo "Building Docker image: ${IMAGE}..."
docker build "${EXTRA_ARGS[@]}" -t "${IMAGE}" "${SCRIPT_DIR}/docker"

echo ""
echo "Done. Image: ${IMAGE}"
docker images "${IMAGE}" --format "Size: {{.Size}}"
