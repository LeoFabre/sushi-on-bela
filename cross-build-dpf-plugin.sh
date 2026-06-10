#!/usr/bin/env bash
# Cross-compile a DPF/CMake plugin for PocketBeagle2 (aarch64) using the
# elk-crossbuild Docker image. Headless (no UI) by default; pass --ui to enable.
#
# Usage:
#   ./cross-build-dpf-plugin.sh /path/to/dpf-plugin-src                          # headless
#   ./cross-build-dpf-plugin.sh /path/to/dpf-plugin-src --ui                     # with UI
#   ./cross-build-dpf-plugin.sh /path/to/dpf-plugin-src --clean                  # wipe cache
#   ./cross-build-dpf-plugin.sh /path/to/dpf-plugin-src --ui-option NAME_BUILD_UI  # override UI option
#
# The plugin's CMake UI option name is auto-detected from its CMakeLists.txt
# (the `option(<X>_BUILD_UI ...)` line). Defaults to MOSES_BUILD_UI if not found.
# Override with --ui-option. The matching tests option is derived as <X>_BUILD_TESTS.
set -euo pipefail
export MSYS_NO_PATHCONV=1

PLUGIN_SRC="${1:?Usage: $0 /path/to/dpf-plugin-src [--clean] [--ui] [--ui-option NAME] [extra cmake args...]}"
shift

IMAGE="elk-crossbuild-bookworm"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_NAME="$(basename "${PLUGIN_SRC}")"
BUILD_VOLUME="${PLUGIN_NAME}-dpf-build-cache"
OUTPUT_DIR="${SCRIPT_DIR}/build-arm64/${PLUGIN_NAME}"
PLUGIN_SRC_ABS="$(cd "${PLUGIN_SRC}" && pwd)"

UI_FLAG="OFF"
UI_OPTION=""
EXTRA_ARGS=()
while (("$#")); do
    case "$1" in
        --clean)     docker volume rm "${BUILD_VOLUME}" 2>/dev/null || true ;;
        --ui)        UI_FLAG="ON" ;;
        --ui-option) shift; UI_OPTION="${1}" ;;
        *)           EXTRA_ARGS+=("$1") ;;
    esac
    shift
done

# Auto-detect the UI option name from the plugin's CMakeLists.txt if not overridden.
if [[ -z "${UI_OPTION}" ]]; then
    UI_OPTION="$(grep -oE 'option\([A-Z_]+_BUILD_UI' "${PLUGIN_SRC_ABS}/CMakeLists.txt" 2>/dev/null \
                 | head -1 | sed -E 's/^option\(//')"
    UI_OPTION="${UI_OPTION:-MOSES_BUILD_UI}"
fi
TESTS_OPTION="${UI_OPTION/_BUILD_UI/_BUILD_TESTS}"

if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
    echo "Building Docker image..."
    docker build -t "${IMAGE}" "${SCRIPT_DIR}/docker"
fi

docker volume create "${BUILD_VOLUME}" >/dev/null 2>&1 || true
echo "Cross-compiling ${PLUGIN_NAME} (DPF, aarch64, UI=${UI_FLAG}, option=${UI_OPTION})..."

docker run --rm \
    -v "${PLUGIN_SRC_ABS}:/workspace/my-plugin" \
    -v "${BUILD_VOLUME}:/workspace/build-plugin" \
    "${IMAGE}" \
    /opt/scripts/build-dpf-plugin.sh /workspace/my-plugin /workspace/build-plugin \
        "${UI_FLAG}" "${UI_OPTION}" "${TESTS_OPTION}" "${EXTRA_ARGS[@]:-}"

mkdir -p "${OUTPUT_DIR}"
echo "Extracting VST3 + LV2 bundles..."
docker run --rm \
    -v "${BUILD_VOLUME}:/workspace/build-plugin:ro" \
    -v "${OUTPUT_DIR}:/output" \
    "${IMAGE}" \
    bash -c '
        find /workspace/build-plugin -name "*.vst3" -type d -exec cp -r {} /output/ \;
        find /workspace/build-plugin -name "*.lv2"  -type d -exec cp -r {} /output/ \;
    '

echo
echo "Done. Output:"
ls -la "${OUTPUT_DIR}"/ 2>/dev/null || true
echo
echo "Copy to device:"
echo "  scp -r \"${OUTPUT_DIR}/\"*.vst3 root@pocketbeagle2:/usr/lib/vst3/"
