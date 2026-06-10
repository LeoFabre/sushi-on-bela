#!/bin/bash
set -euo pipefail

# Override via environment: SUSHI=/path/to/sushi BUILD=... VCPKG_ROOT=... ./wsl-build-sushi.sh
export SUSHI="${SUSHI:-$HOME/sushi}"
export BUILD="${BUILD:-/tmp/build-sushi}"
export VCPKG_ROOT="${VCPKG_ROOT:-$HOME/vcpkg}"

rm -rf "$BUILD"
mkdir -p "$BUILD"

echo "=== Starting cmake configure ==="
cmake "$SUSHI" -B "$BUILD" \
    -DCMAKE_TOOLCHAIN_FILE="$VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake" \
    -DVCPKG_CHAINLOAD_TOOLCHAIN_FILE=/opt/toolchain-aarch64-elk.cmake \
    -DVCPKG_TARGET_TRIPLET=arm64-elk-linux \
    -DVCPKG_HOST_TRIPLET=x64-linux \
    -DCMAKE_BUILD_TYPE=Release \
    -DSUSHI_BUILD_TWINE=ON \
    -DSUSHI_TWINE_STATIC=ON \
    -DTWINE_WITH_TESTS=OFF \
    -DSUSHI_WITH_JACK=OFF \
    -DSUSHI_WITH_PORTAUDIO=OFF \
    -DSUSHI_WITH_ALSA_MIDI=ON \
    -DSUSHI_WITH_RT_MIDI=OFF \
    -DSUSHI_WITH_VST3=ON \
    -DSUSHI_WITH_LV2=ON \
    -DSUSHI_WITH_LV2_MDA_TESTS=OFF \
    -DSUSHI_WITH_RPC_INTERFACE=ON \
    -DSUSHI_AUDIO_BUFFER_SIZE=64 \
    -DSUSHI_WITH_UNIT_TESTS=OFF \
    -DSUSHI_BUILD_WITH_SANITIZERS=OFF \
    -DSUSHI_WITH_RASPA=OFF

echo "=== Starting build ==="
cmake --build "$BUILD" -j"$(nproc)"

echo "=== BUILD COMPLETE ==="
