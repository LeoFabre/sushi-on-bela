#!/usr/bin/env bash
# Cross-compile Sushi (reactive library) for PocketBeagle2 (aarch64) using
# the elk-crossbuild Docker image, with persistent vcpkg and build caches.
#
# Usage:
#   ./cross-build-sushi.sh /path/to/sushi             # incremental build
#   ./cross-build-sushi.sh /path/to/sushi --clean      # wipe all caches first
#
# Requires: docker, elk-crossbuild image (built from sushi/docker/Dockerfile).

set -euo pipefail
export MSYS_NO_PATHCONV=1

SUSHI_SRC="${1:?Usage: $0 /path/to/sushi [--clean] [extra cmake args...]}"
shift

IMAGE="elk-crossbuild-bookworm"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
    echo "Docker image '${IMAGE}' not found. Building it..."
    docker build -t "${IMAGE}" "${SCRIPT_DIR}/docker"
fi
OUTPUT_DIR="${SCRIPT_DIR}/build-arm64/sushi"

BUILD_VOLUME="sushi-build-cache-bw"
VCPKG_CACHE_VOLUME="sushi-vcpkg-cache-bw"

if [[ "${1:-}" == "--clean" ]]; then
    echo "Removing build caches..."
    docker volume rm "${BUILD_VOLUME}" 2>/dev/null || true
    docker volume rm "${VCPKG_CACHE_VOLUME}" 2>/dev/null || true
    docker volume rm "${VCPKG_CACHE_VOLUME}-installed" 2>/dev/null || true
    docker volume rm "${VCPKG_CACHE_VOLUME}-packages" 2>/dev/null || true
    shift
fi

EXTRA_ARGS=("$@")

docker volume create "${BUILD_VOLUME}" >/dev/null 2>&1 || true
docker volume create "${VCPKG_CACHE_VOLUME}" >/dev/null 2>&1 || true

SUSHI_SRC_ABS="$(cd "${SUSHI_SRC}" && pwd)"

echo "Cross-compiling Sushi reactive (aarch64)..."

docker run --rm \
    -v "${SUSHI_SRC_ABS}:/workspace/sushi" \
    -v "${BUILD_VOLUME}:/workspace/build-sushi" \
    -v "${VCPKG_CACHE_VOLUME}:/opt/vcpkg/buildtrees" \
    -v "${VCPKG_CACHE_VOLUME}-installed:/opt/vcpkg/installed" \
    -v "${VCPKG_CACHE_VOLUME}-packages:/opt/vcpkg/packages" \
    "${IMAGE}" \
    /opt/scripts/build-sushi.sh --reactive /workspace/sushi /workspace/build-sushi \
        -DALSA_DIR=/usr/include \
        "${EXTRA_ARGS[@]}"

mkdir -p "${OUTPUT_DIR}"

echo "Extracting build artefacts..."

docker run --rm \
    -v "${BUILD_VOLUME}:/workspace/build-sushi:ro" \
    -v "${OUTPUT_DIR}:/output" \
    "${IMAGE}" \
    bash -c 'cp /workspace/build-sushi/libsushi_library.a /output/ && \
             if [ -f /workspace/build-sushi/apps/sushi ]; then cp /workspace/build-sushi/apps/sushi /output/; fi'

echo ""
echo "Done. Output:"
ls -la "${OUTPUT_DIR}"/
echo ""
echo "Deploy:"
echo "  scp \"${OUTPUT_DIR}/libsushi_library.a\" root@pocketbeagle2:/usr/lib/"
