#!/usr/bin/env bash
# Cross-compile a JUCE plugin for PocketBeagle2 (aarch64) using the
# elk-crossbuild Docker image, and extract the VST3 bundle locally.
#
# Usage:
#   ./cross-build-plugin.sh /path/to/plugin-src          # build and extract
#   ./cross-build-plugin.sh /path/to/plugin-src --clean   # wipe cache first
#
# Requires: docker, elk-crossbuild image (built from sushi/docker/Dockerfile).

set -euo pipefail
export MSYS_NO_PATHCONV=1

PLUGIN_SRC="${1:?Usage: $0 /path/to/plugin-src [--clean] [extra cmake args...]}"
shift

IMAGE="elk-crossbuild-bookworm"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
    echo "Docker image '${IMAGE}' not found. Building it..."
    docker build -t "${IMAGE}" "${SCRIPT_DIR}/docker"
fi
PLUGIN_NAME="$(basename "${PLUGIN_SRC}")"
BUILD_VOLUME="${PLUGIN_NAME}-build-cache"
OUTPUT_DIR="$(cd "$(dirname "$0")" && pwd)/build-arm64/${PLUGIN_NAME}"

if [[ "${1:-}" == "--clean" ]]; then
    echo "Removing build cache volume..."
    docker volume rm "${BUILD_VOLUME}" 2>/dev/null || true
    shift
fi

EXTRA_ARGS=("$@")
DOCKER_ENV_ARGS=()

if [[ -d "${PLUGIN_SRC}/WebViewPluginDemoGUI" ]]; then
    DOCKER_ENV_ARGS+=(-e CI=1)
fi

docker volume create "${BUILD_VOLUME}" >/dev/null 2>&1 || true

PLUGIN_SRC_ABS="$(cd "${PLUGIN_SRC}" && pwd)"

echo "Cross-compiling ${PLUGIN_NAME} (headless VST3, aarch64)..."

# Mount plugin source as writable so the build script can patch JUCE's
# juceaide CMakeLists.txt for cross-compilation. Restore afterward.
restore_juce() {
    git -C "${PLUGIN_SRC_ABS}" checkout -- . 2>/dev/null || true
}
trap restore_juce EXIT

docker run --rm \
    "${DOCKER_ENV_ARGS[@]}" \
    -v "${PLUGIN_SRC_ABS}:/workspace/my-plugin" \
    -v "${BUILD_VOLUME}:/workspace/build-plugin" \
    "${IMAGE}" \
    /opt/scripts/build-juce-plugin.sh /workspace/my-plugin /workspace/build-plugin \
        "${EXTRA_ARGS[@]}"

restore_juce
trap - EXIT

mkdir -p "${OUTPUT_DIR}"

echo "Extracting VST3 bundle..."

docker run --rm \
    "${DOCKER_ENV_ARGS[@]}" \
    -v "${BUILD_VOLUME}:/workspace/build-plugin:ro" \
    -v "${OUTPUT_DIR}:/output" \
    "${IMAGE}" \
    bash -c 'find /workspace/build-plugin -name "*.vst3" -type d -exec cp -r {} /output/ \;'

echo ""
echo "Done. Output:"
ls -la "${OUTPUT_DIR}"/ 2>/dev/null
echo ""
echo "Copy to device:"
echo "  scp -r \"${OUTPUT_DIR}/\"*.vst3 root@pocketbeagle2:/usr/lib/vst3/"
