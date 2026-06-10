#!/usr/bin/env bash
# Pull libraries and headers from a Bela board to populate bela-sysroot/.
# This must be run once before cross-compiling the Bela project.
#
# Usage:
#   ./setup-bela-sysroot.sh              # pull from bela.local
#   ./setup-bela-sysroot.sh 192.168.7.2  # pull from a specific address

set -euo pipefail

BELA_HOST="${1:-bela.local}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SYSROOT="${SCRIPT_DIR}/bela-sysroot"
SSH="ssh -o StrictHostKeyChecking=no root@${BELA_HOST}"
SCP="scp -o StrictHostKeyChecking=no"

echo "Setting up bela-sysroot from root@${BELA_HOST}..."

# Check connectivity
if ! ${SSH} "echo ok" >/dev/null 2>&1; then
    echo "ERROR: Cannot connect to root@${BELA_HOST}" >&2
    echo "  Make sure the Bela is connected and accessible." >&2
    exit 1
fi

# Create directory structure
mkdir -p "${SYSROOT}/lib/evl"
mkdir -p "${SYSROOT}/lib/aarch64-linux-gnu"
mkdir -p "${SYSROOT}/include"
mkdir -p "${SYSROOT}/usr/include"

# ── Bela libraries ────────────────────────────────────────────────────────────
echo "Pulling Bela libraries..."
${SCP} "root@${BELA_HOST}:/root/Bela/lib/libbela.so"      "${SYSROOT}/lib/"
${SCP} "root@${BELA_HOST}:/root/Bela/lib/libbela.a"       "${SYSROOT}/lib/"
${SCP} "root@${BELA_HOST}:/root/Bela/lib/libbelaextra.so"  "${SYSROOT}/lib/"
${SCP} "root@${BELA_HOST}:/root/Bela/lib/libbelaextra.a"   "${SYSROOT}/lib/"

# ── Bela headers ──────────────────────────────────────────────────────────────
echo "Pulling Bela headers..."
${SCP} -r "root@${BELA_HOST}:/root/Bela/include/*" "${SYSROOT}/include/"

# ── Bela default_main.cpp (entry point) ──────────────────────────────────────
echo "Pulling default_main.cpp..."
${SCP} "root@${BELA_HOST}:/root/Bela/core/default_main.cpp" "${SYSROOT}/"

# ── EVL (real-time subsystem) ─────────────────────────────────────────────────
# libevl 0.5x installs under /usr/evl/ on the Bookworm Bela image
# (older images used /usr/lib/aarch64-linux-gnu/evl/ — kept as fallback).
echo "Pulling EVL libraries + headers..."
if ${SSH} "test -d /usr/evl"; then
    mkdir -p "${SYSROOT}/usr/evl"
    ${SSH} "tar -C /usr/evl -cf - lib include" | tar -C "${SYSROOT}/usr/evl" -xf -
    cp "${SYSROOT}/usr/evl/lib/aarch64-linux-gnu/libevl.a"   "${SYSROOT}/lib/evl/"
    cp "${SYSROOT}/usr/evl/lib/aarch64-linux-gnu/libevl.so"* "${SYSROOT}/lib/evl/" 2>/dev/null || true
else
    ${SCP} "root@${BELA_HOST}:/usr/lib/aarch64-linux-gnu/evl/libevl.a"  "${SYSROOT}/lib/evl/"
    ${SCP} "root@${BELA_HOST}:/usr/lib/aarch64-linux-gnu/evl/libevl.so" "${SYSROOT}/lib/evl/" 2>/dev/null || true
fi

# ── System shared libs (for dynamic linking) ──────────────────────────────────
echo "Pulling system libraries..."
SYSTEM_LIBS=(
    /lib/aarch64-linux-gnu/ld-linux-aarch64.so.1
    /lib/aarch64-linux-gnu/libc.so.6
    /lib/aarch64-linux-gnu/libm.so.6
    /lib/aarch64-linux-gnu/libdl.so.2
    /lib/aarch64-linux-gnu/libpthread.so.0
    /lib/aarch64-linux-gnu/librt.so.1
    /usr/lib/aarch64-linux-gnu/libstdc++.so.6
    /usr/lib/aarch64-linux-gnu/libgcc_s.so.1
    /usr/lib/aarch64-linux-gnu/libatomic.so.1
    /usr/lib/aarch64-linux-gnu/libasound.so.2
)
for lib in "${SYSTEM_LIBS[@]}"; do
    filename="$(basename "${lib}")"
    ${SCP} "root@${BELA_HOST}:${lib}" "${SYSROOT}/lib/aarch64-linux-gnu/${filename}" 2>/dev/null || \
        echo "  WARNING: ${lib} not found on Bela (skipped)"
done

# ld-linux also needed at sysroot root for the linker
cp "${SYSROOT}/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1" "${SYSROOT}/lib/" 2>/dev/null || true

# ── Seasocks (used by Bela for WebSocket) ─────────────────────────────────────
echo "Pulling seasocks..."
${SCP} "root@${BELA_HOST}:/usr/lib/aarch64-linux-gnu/libseasocks.so" "${SYSROOT}/lib/" 2>/dev/null || \
${SCP} "root@${BELA_HOST}:/usr/local/lib/libseasocks.so" "${SYSROOT}/lib/" 2>/dev/null || \
    echo "  WARNING: libseasocks.so not found (may need manual copy)"

echo ""
echo "Done. Sysroot at: ${SYSROOT}/"
echo ""
ls -lh "${SYSROOT}/lib/"*.{a,so} 2>/dev/null
echo ""
echo "Next: ./cross-build-sushi.sh /path/to/sushi"
