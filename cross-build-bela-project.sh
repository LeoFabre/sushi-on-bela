#!/usr/bin/env bash
# Cross-compile the Bela project (render.cpp + sushi + all deps) into a final
# binary, ready to deploy to the Bela board.
#
# Usage:
#   ./cross-build-bela-project.sh /path/to/sushi
#
# Requires:
#   - docker + elk-crossbuild image
#   - sushi already cross-compiled (run cross-build-sushi.sh first)
#   - bela-sysroot/ populated (libs + headers from the Bela board)
#
# Output: build-arm64/bela-project/sushi  (the final binary)

set -euo pipefail
export MSYS_NO_PATHCONV=1

SUSHI_SRC="${1:?Usage: $0 /path/to/sushi}"

IMAGE="elk-crossbuild-bookworm"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
    echo "Docker image '${IMAGE}' not found. Building it..."
    docker build -t "${IMAGE}" "${SCRIPT_DIR}/docker"
fi
OUTPUT_DIR="${SCRIPT_DIR}/build-arm64/bela-project"
SUSHI_SRC_ABS="$(cd "${SUSHI_SRC}" && pwd)"
BELA_SYSROOT="${SCRIPT_DIR}/bela-sysroot"
PROJECT_DIR="${SCRIPT_DIR}/bela-project"

BUILD_VOLUME="sushi-build-cache-bw"

if [[ ! -d "${BELA_SYSROOT}/lib" ]]; then
    echo "ERROR: bela-sysroot/lib not found. Copy Bela libs first:" >&2
    echo "  scp root@bela.local:/root/Bela/lib/libbela*.{so,a} bela-sysroot/lib/" >&2
    exit 1
fi

mkdir -p "${OUTPUT_DIR}"

echo "Cross-compiling Bela project (aarch64)..."

docker run --rm \
    -e SUSHI_CHUNK="${SUSHI_CHUNK:-64}" \
    -v "${SUSHI_SRC_ABS}:/workspace/sushi:ro" \
    -v "${BUILD_VOLUME}:/workspace/build-sushi:ro" \
    -v "${PROJECT_DIR}:/workspace/project:ro" \
    -v "${BELA_SYSROOT}:/workspace/bela-sysroot:ro" \
    -v "${OUTPUT_DIR}:/output" \
    "${IMAGE}" \
    bash -c '
set -euo pipefail

CC=aarch64-linux-gnu-gcc
CXX=aarch64-linux-gnu-g++
BUILD=/workspace/build-sushi
SYSROOT=/workspace/bela-sysroot
SUSHI=/workspace/sushi

# Compile render.cpp
# SUSHI_CHUNK must match the SUSHI_AUDIO_BUFFER_SIZE the library was built with
# (ChunkSampleBuffer is sized by this define on both sides — mismatch corrupts memory).
SUSHI_CHUNK="${SUSHI_CHUNK:-64}"
echo "Compiling render.cpp (chunk=${SUSHI_CHUNK})..."
$CXX -std=c++20 -O2 \
    -DSUSHI_CUSTOM_AUDIO_CHUNK_SIZE=${SUSHI_CHUNK} \
    -I${SYSROOT}/include \
    -I${SUSHI}/include \
    -I${SUSHI}/twine/include \
    -I${SUSHI}/twine/elk-warning-suppressor/include \
    -I${SUSHI}/third-party/rapidjson/include \
    -I${SUSHI}/elklog/third-party/spdlog/include \
    -I${SUSHI}/third-party/optionparser \
    -I${BUILD} \
    -c /workspace/project/render.cpp \
    -o /tmp/render.o

# Compile default_main.cpp
echo "Compiling default_main.cpp..."
$CXX -std=c++20 -O2 \
    -I${SYSROOT}/include \
    -c ${SYSROOT}/default_main.cpp \
    -o /tmp/default_main.o

# Link everything — use --start-group/--end-group to resolve circular deps
echo "Linking..."

SUSHI_LIBS="-lsushi_library -lsushi_rpc -lvst3_host -llv2_host -loscpack \
    -lelklog -lspdlog -ltwine_static \
    -lbase -lsdk -lsdk_common -lpluginterfaces -lfreeverb"

VCPKG_LIBS="-lgrpc++ -lgrpc -lgpr -lprotobuf \
    -laddress_sorting \
    -lupb_message_lib -lupb_mem_lib -lupb_base_lib \
    -lupb_wire_lib -lupb_mini_table_lib -lupb_mini_descriptor_lib \
    -lupb_hash_lib -lupb_json_lib -lupb_lex_lib \
    -lupb_reflection_lib -lupb_textformat_lib \
    -lutf8_range -lutf8_validity \
    -lre2 -lcares -lssl -lcrypto -lz \
    -lsndfile -llilv-0 -lserd-0 -lsord-0 -lsratom-0 -lzix-0 \
    -lrtmidi \
    -lsentry \
    -lcrashpad_client -lcrashpad_util -lcrashpad_compat \
    -lcrashpad_snapshot -lcrashpad_minidump -lcrashpad_mpack \
    -lcrashpad_tools -lcrashpad_handler_lib -lmini_chromium \
    -lcurl -llzma \
    -lunwind -lunwind-aarch64"

ABSEIL_LIBS=$(find ${BUILD}/vcpkg_installed/arm64-elk-linux/lib -name "libabsl_*.a" \
    | sed "s|.*/lib|-l|;s|\.a||" | sort | tr "\n" " ")

$CXX -no-pie -pthread -o /output/sushi \
    /tmp/default_main.o \
    /tmp/render.o \
    -L${SYSROOT}/lib \
    -L${SYSROOT}/lib/evl \
    -L${BUILD} \
    -L${BUILD}/elklog \
    -L${BUILD}/elklog/third-party/spdlog \
    -L${BUILD}/twine \
    -L${BUILD}/rpc_interface \
    -L${BUILD}/third-party/lv2_host \
    -L${BUILD}/third-party/oscpack \
    -L${BUILD}/lib/Release \
    -L${BUILD}/vcpkg_installed/arm64-elk-linux/lib \
    -lbela -lbelaextra \
    -Wl,--start-group \
    ${SUSHI_LIBS} ${VCPKG_LIBS} ${ABSEIL_LIBS} \
    -Wl,--end-group \
    ${SYSROOT}/lib/evl/libevl.a -lseasocks \
    -lasound -lpthread -ldl -lrt -lstdc++fs -latomic -lm

echo ""
echo "Binary size: $(du -h /output/sushi | cut -f1)"
echo "Done."
'

echo ""
echo "Output: ${OUTPUT_DIR}/sushi"
ls -lh "${OUTPUT_DIR}/sushi"
echo ""
echo "Deploy:"
echo "  scp \"${OUTPUT_DIR}/sushi\" root@bela.local:/root/Bela/projects/sushi/"
