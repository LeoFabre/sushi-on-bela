#!/usr/bin/env bash
# Cross-compile a JUCE VST3 plugin for PocketBeagle2 (aarch64 / Elk Audio OS).
#
# Usage:
#   build-juce-plugin.sh [PLUGIN_SRC] [BUILD_DIR] [extra cmake args...]
#
# The plugin source must be mounted into the container. Example:
#   docker run --rm -it -v /path/to/plugin:/workspace/plugin elk-crossbuild
#   /opt/scripts/build-juce-plugin.sh /workspace/plugin /workspace/build-plugin
#
# The plugin's CMakeLists.txt must use the standard JUCE CMake API:
#
#   find_package(JUCE CONFIG REQUIRED)
#   juce_add_plugin(MyPlugin FORMATS VST3 ...)
#
# Key defines for headless (no GUI) operation inside Sushi:
#   JUCE_HEADLESS_PLUGIN_CLIENT=1
#   JUCE_DISPLAY_SPLASH_SCREEN=0
#   JUCE_WEB_BROWSER=0
#   JUCE_USE_CURL=0

set -euo pipefail

PLUGIN_SRC="${1:-/workspace/plugin}"
BUILD_DIR="${2:-/workspace/build-plugin}"
shift 2 2>/dev/null || true

# ── Sanity check ──────────────────────────────────────────────────────────────

if [[ ! -f "${PLUGIN_SRC}/CMakeLists.txt" ]]; then
    echo "ERROR: Plugin source not found at ${PLUGIN_SRC}" >&2
    echo "  Mount the plugin repo into the container, e.g.:" >&2
    echo "    docker run -v /path/to/plugin:/workspace/plugin elk-crossbuild" >&2
    exit 1
fi

# ── Configure + Build ─────────────────────────────────────────────────────────
# JUCE automatically builds juceaide as a native host tool during cmake configure
# when CMAKE_CROSSCOMPILING is set (which our toolchain does).

mkdir -p "${BUILD_DIR}"

# Some JUCE/plugin sources rely on standard-library symbols without including
# the headers or using portable names. Inject a tiny C++ compatibility header
# instead of patching external plugin repositories.
COMPAT_HEADER="/tmp/juce-crossbuild-compat.h"
printf '%s\n' \
    '#pragma once' \
    '#include <utility>' \
    '#include <cmath>' \
    'namespace std { using ::powf; }' \
    > "${COMPAT_HEADER}"
export CXXFLAGS="${CXXFLAGS:-} -include ${COMPAT_HEADER}"

patch_juce_tree() {
    local juce_root="$1"
    local patched=1

    local juceaide_cmake="${juce_root}/extras/Build/juceaide/CMakeLists.txt"
    if [[ -f "${juceaide_cmake}" ]]; then
        echo "Patching juceaide CMakeLists.txt for cross-compilation..."
        sed -i 's|^#\s*unset(ENV{ASM})|        unset(ENV{ASM})|' "${juceaide_cmake}"
        sed -i 's|^#\s*unset(ENV{CC})|        unset(ENV{CC})|' "${juceaide_cmake}"
        sed -i 's|^#\s*unset(ENV{CXX})|        unset(ENV{CXX})|' "${juceaide_cmake}"
        # Prevent cross-compilation PKG_CONFIG paths from leaking into juceaide's
        # native sub-cmake (otherwise pkg-config can't find host freetype2).
        if ! grep -q 'unset(ENV{PKG_CONFIG_LIBDIR})' "${juceaide_cmake}"; then
            sed -i '/unset(ENV{CXX})/a\        unset(ENV{PKG_CONFIG_LIBDIR})\n        unset(ENV{PKG_CONFIG_SYSROOT_DIR})' "${juceaide_cmake}"
        fi
        patched=0
    fi

    local juce_utils="${juce_root}/extras/Build/CMake/JUCEUtils.cmake"
    if [[ -f "${juce_utils}" ]] && grep -q 'VST3_AUTO_MANIFEST TRUE' "${juce_utils}"; then
        echo "Disabling JUCE VST3 auto-manifest helper for cross-compilation..."
        sed -i 's|VST3_AUTO_MANIFEST TRUE|VST3_AUTO_MANIFEST FALSE|' "${juce_utils}"
        patched=0
    fi

    return "${patched}"
}

for candidate in "${PLUGIN_SRC}/JUCE" "${PLUGIN_SRC}/modules/juce" "${PLUGIN_SRC}/juce"; do
    if [[ -d "${candidate}" ]]; then
        patch_juce_tree "${candidate}" || true
    fi
done

cmake_args=(
    "${PLUGIN_SRC}"
    -B "${BUILD_DIR}"
    -DCMAKE_TOOLCHAIN_FILE=/opt/toolchain-aarch64-elk.cmake
    -DCMAKE_BUILD_TYPE=Release
    -DVST3_AUTO_MANIFEST=FALSE
    -DCMAKE_STRIP=aarch64-linux-gnu-strip
    -DFETCHCONTENT_QUIET=OFF
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=TRUE
    -DCMAKE_CXX_FLAGS_RELEASE="-Os -DNDEBUG -fdata-sections -ffunction-sections"
    -DCMAKE_C_FLAGS_RELEASE="-Os -DNDEBUG -fdata-sections -ffunction-sections"
    -DCMAKE_SHARED_LINKER_FLAGS_RELEASE="-Wl,--gc-sections"
    -DCMAKE_MODULE_LINKER_FLAGS_RELEASE="-Wl,--gc-sections"
    "$@"
)

cmake "${cmake_args[@]}"

patched_fetched_juce=1
while IFS= read -r fetched_juce; do
    patch_juce_tree "${fetched_juce}" && continue
    patched_fetched_juce=0
done < <(find "${BUILD_DIR}/_deps" -maxdepth 1 -type d -name '*juce*-src' 2>/dev/null || true)

if [[ "${patched_fetched_juce}" -eq 0 ]]; then
    echo "Reconfiguring after patching fetched JUCE..."
    cmake "${cmake_args[@]}"
fi

cmake --build "${BUILD_DIR}" -j"$(nproc)"

echo ""
echo "Stripping debug symbols..."
find "${BUILD_DIR}" -name "*.so" -exec aarch64-linux-gnu-strip --strip-all {} \;

echo ""
echo "Plugin built successfully."

VST3_BUNDLE=$(find "${BUILD_DIR}" -maxdepth 6 -name "*.vst3" -type d 2>/dev/null | head -1)
if [[ -n "${VST3_BUNDLE}" ]]; then
    echo "  VST3 bundle: ${VST3_BUNDLE}"
    echo ""
    echo "  Verify architecture (should show aarch64 ELF):"
    echo "    file \"${VST3_BUNDLE}/Contents/aarch64-linux/\"*.so"
    echo ""
    echo "  Copy to device:"
    echo "    scp -r \"${VST3_BUNDLE}\" root@pocketbeagle2:/usr/lib/vst3/"
fi
