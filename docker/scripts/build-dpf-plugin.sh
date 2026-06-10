#!/usr/bin/env bash
# Inside the Docker image: configure & build a DPF/CMake plugin using the
# aarch64 toolchain.
# Args: <plugin-src> <build-dir> <UI_FLAG: ON|OFF> [UI_OPTION=MOSES_BUILD_UI] [TESTS_OPTION=MOSES_BUILD_TESTS] [extra cmake args]
# UI_OPTION / TESTS_OPTION let this build any DPF plugin whose CMake option names
# differ from Moses' (e.g. DUBWIZE_BUILD_UI / DUBWIZE_BUILD_TESTS).
set -euo pipefail
PLUGIN_SRC="${1}"
BUILD_DIR="${2}"
UI_FLAG="${3:-OFF}"
UI_OPTION="${4:-MOSES_BUILD_UI}"
TESTS_OPTION="${5:-MOSES_BUILD_TESTS}"
shift 5 2>/dev/null || true

# Make sure DPF's sub-submodules (pugl etc.) are initialized.
if [[ -d "${PLUGIN_SRC}/dpf" && -f "${PLUGIN_SRC}/dpf/.gitmodules" ]]; then
    git -C "${PLUGIN_SRC}/dpf" submodule update --init --recursive --depth 1 2>/dev/null || true
fi

cmake -S "${PLUGIN_SRC}" -B "${BUILD_DIR}" \
    -DCMAKE_TOOLCHAIN_FILE=/opt/toolchain-aarch64-elk.cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -D"${UI_OPTION}"="${UI_FLAG}" \
    -D"${TESTS_OPTION}"=OFF \
    "$@"

cmake --build "${BUILD_DIR}" -j"$(nproc)"
