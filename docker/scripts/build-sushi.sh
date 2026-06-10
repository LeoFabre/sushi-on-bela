#!/usr/bin/env bash
# Cross-compile Sushi for PocketBeagle2 (aarch64 / Elk Audio OS).
#
# Usage:
#   build-sushi.sh [--reactive] [SUSHI_SRC] [BUILD_DIR] [extra cmake args...]
#
# Modes:
#   (default)   Standalone Sushi for Elk Audio OS.
#               raspa + EVL provide hard-RT audio. Twine built with EVL workers.
#
#   --reactive  Sushi as a library for embedding in a Bela render() callback.
#               Bela's PRU + Xenomai thread drives audio — no raspa/EVL needed.
#               Twine built in POSIX mode (render() is already in the Xenomai RT
#               thread; twine worker threads are pthreads, safe for multi-core DSP).
#
# The Sushi source must be mounted into the container. Example:
#   docker run --rm -it -v /path/to/sushi:/workspace/sushi elk-crossbuild
#   /opt/scripts/build-sushi.sh /workspace/sushi /workspace/build-sushi
#
# Prerequisites:
#   git submodule update --init --recursive   (in SUSHI_SRC, except twine)
#   twine: initialised automatically from /opt/twine-src if submodule missing.

set -euo pipefail

# Docker Desktop on Windows/WSL2 can have clock drift; meson aborts on skew.
# Resync if possible (needs CAP_SYS_TIME or --privileged).
hwclock -s 2>/dev/null || date -s "$(date -R)" 2>/dev/null || true

# ── Parse --reactive flag ──────────────────────────────────────────────────────

REACTIVE=false
if [[ "${1:-}" == "--reactive" ]]; then
    REACTIVE=true
    shift
fi

SUSHI_SRC="${1:-/workspace/sushi}"
BUILD_DIR="${2:-/workspace/build-sushi}"
shift 2 2>/dev/null || true

# ── Sanity check ──────────────────────────────────────────────────────────────

if [[ ! -f "${SUSHI_SRC}/CMakeLists.txt" ]]; then
    echo "ERROR: Sushi source not found at ${SUSHI_SRC}" >&2
    echo "  Mount the sushi repo into the container, e.g.:" >&2
    echo "    docker run -v /path/to/sushi:/workspace/sushi elk-crossbuild" >&2
    exit 1
fi

# ── Twine setup ───────────────────────────────────────────────────────────────

if [[ ! -f "${SUSHI_SRC}/twine/CMakeLists.txt" ]]; then
    echo "twine submodule not initialised — symlinking /opt/twine-src"
    ln -sfn /opt/twine-src "${SUSHI_SRC}/twine"
fi

# ── Common cmake flags ────────────────────────────────────────────────────────

COMMON_FLAGS=(
    -DCMAKE_TOOLCHAIN_FILE="${VCPKG_ROOT}/scripts/buildsystems/vcpkg.cmake"
    -DVCPKG_CHAINLOAD_TOOLCHAIN_FILE=/opt/toolchain-aarch64-elk.cmake
    -DVCPKG_TARGET_TRIPLET="${VCPKG_TARGET_TRIPLET:-arm64-elk-linux}"
    -DVCPKG_HOST_TRIPLET="${VCPKG_HOST_TRIPLET:-x64-linux}"
    -DVCPKG_OVERLAY_PORTS=/opt/overlay-ports
    -DCMAKE_BUILD_TYPE=Release
    -DSUSHI_BUILD_TWINE=ON
    -DSUSHI_TWINE_STATIC=ON
    -DTWINE_WITH_TESTS=OFF
    -DSUSHI_WITH_JACK=OFF
    -DSUSHI_WITH_PORTAUDIO=OFF
    -DSUSHI_WITH_ALSA_MIDI=ON
    -DSUSHI_WITH_RT_MIDI=OFF
    -DSUSHI_WITH_VST3=ON
    -DSUSHI_WITH_LV2=ON
    -DSUSHI_WITH_LV2_MDA_TESTS=OFF
    -DSUSHI_WITH_RPC_INTERFACE=ON
    -DSUSHI_AUDIO_BUFFER_SIZE=64
    -DSUSHI_WITH_UNIT_TESTS=OFF
    -DSUSHI_BUILD_WITH_SANITIZERS=OFF
)

# ── Mode-specific flags + build ───────────────────────────────────────────────

mkdir -p "${BUILD_DIR}"

if $REACTIVE; then
    echo "Mode: reactive library for Bela (POSIX twine, no raspa/EVL)"

    cmake "${SUSHI_SRC}" -B "${BUILD_DIR}" \
        "${COMMON_FLAGS[@]}" \
        -DSUSHI_WITH_RASPA=OFF \
        "$@"
else
    echo "Mode: standalone Elk Audio OS (EVL twine + raspa)"

    cmake "${SUSHI_SRC}" -B "${BUILD_DIR}" \
        "${COMMON_FLAGS[@]}" \
        -DSUSHI_WITH_RASPA=ON \
        -DSUSHI_RASPA_FLAVOR=evl \
        "$@"
fi

cmake --build "${BUILD_DIR}" -j"$(nproc)"

# ── Report ────────────────────────────────────────────────────────────────────

echo ""

if $REACTIVE; then
    LIB="${BUILD_DIR}/libsushi_library.a"
    echo "Sushi reactive library built."
    echo "  Library : ${LIB}"
    echo "  Headers : ${SUSHI_SRC}/include/sushi/"
    echo ""
    echo "In your Bela project CMakeLists.txt:"
    echo "  add_library(sushi_library STATIC IMPORTED)"
    echo "  set_target_properties(sushi_library PROPERTIES"
    echo "      IMPORTED_LOCATION ${LIB})"
    echo "  target_include_directories(my_project PRIVATE ${SUSHI_SRC}/include)"
    echo "  target_link_libraries(my_project sushi_library)"
    echo ""
    echo "In render.cpp:"
    echo "  #include <sushi/reactive_factory.h>"
else
    echo "Sushi standalone built."
    echo "  Binary: ${BUILD_DIR}/apps/sushi"
    echo "  Copy:   scp ${BUILD_DIR}/apps/sushi root@pocketbeagle2:/usr/bin/"
fi
