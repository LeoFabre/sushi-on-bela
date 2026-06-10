# CMake cross-compilation toolchain for PocketBeagle2
# Target: TI AM625x / ARM Cortex-A53 (aarch64) running Elk Audio OS + EVL
#
# Usage (direct):
#   cmake /path/to/project -DCMAKE_TOOLCHAIN_FILE=/opt/toolchain-aarch64-elk.cmake
#
# Usage (via vcpkg — preferred for Sushi):
#   Declared as VCPKG_CHAINLOAD_TOOLCHAIN_FILE in the arm64-elk-linux triplet;
#   pass -DCMAKE_TOOLCHAIN_FILE=/opt/vcpkg/scripts/buildsystems/vcpkg.cmake.

cmake_minimum_required(VERSION 3.22)

# ── Target system ─────────────────────────────────────────────────────────────

set(CMAKE_SYSTEM_NAME      Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

# ── Cross-compiler ────────────────────────────────────────────────────────────

set(CMAKE_C_COMPILER   aarch64-linux-gnu-gcc)
set(CMAKE_CXX_COMPILER aarch64-linux-gnu-g++)
set(CMAKE_AR           aarch64-linux-gnu-ar   CACHE FILEPATH "Archiver")
set(CMAKE_RANLIB       aarch64-linux-gnu-ranlib)
set(CMAKE_STRIP        aarch64-linux-gnu-strip)
set(CMAKE_LINKER       aarch64-linux-gnu-ld)
set(CMAKE_OBJCOPY      aarch64-linux-gnu-objcopy)

# ── CPU tuning ────────────────────────────────────────────────────────────────
# ARMv8-A baseline covers both AM625x (Cortex-A53) and RPi4 (Cortex-A72).
# -mtune=cortex-a53 hints the scheduler without restricting the ISA.

add_compile_options(-march=armv8-a -mtune=cortex-a53)

# ── Sysroot / library search paths ────────────────────────────────────────────

list(APPEND CMAKE_FIND_ROOT_PATH
    /opt/elk-sysroot
    /opt/juce-installed
    /usr/aarch64-linux-gnu
    /usr/lib/aarch64-linux-gnu
)

set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE BOTH)

# ── pkg-config ────────────────────────────────────────────────────────────────

set(ENV{PKG_CONFIG_LIBDIR}
    "/opt/elk-sysroot/usr/lib/pkgconfig:/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig")
set(ENV{PKG_CONFIG_SYSROOT_DIR} "/")

# ── Linker search paths ───────────────────────────────────────────────────────

set(CMAKE_EXE_LINKER_FLAGS_INIT
    "-L/opt/elk-sysroot/usr/lib -L/usr/lib/aarch64-linux-gnu")
set(CMAKE_SHARED_LINKER_FLAGS_INIT
    "-L/opt/elk-sysroot/usr/lib -L/usr/lib/aarch64-linux-gnu")
set(CMAKE_MODULE_LINKER_FLAGS_INIT
    "-L/opt/elk-sysroot/usr/lib -L/usr/lib/aarch64-linux-gnu")

# ── JUCE headless / cross-compilation defaults ────────────────────────────────

set(VST3_AUTO_MANIFEST OFF CACHE BOOL "Disable auto VST3 manifest (required for cross-compilation)" FORCE)

# Freetype/fontconfig headers are arch-independent; the x64 -dev packages
# install them in /usr/include/ which the cross-compiler can reach, but
# freetype2 needs an explicit -I for its non-standard subdirectory layout.
set(CMAKE_C_FLAGS_INIT   "${CMAKE_C_FLAGS_INIT} -I/usr/include/freetype2")
set(CMAKE_CXX_FLAGS_INIT "${CMAKE_CXX_FLAGS_INIT} -I/usr/include/freetype2")

# JUCE's juce_graphics links freetype/fontconfig on Linux. Since we skip the
# ARM64 .pc files (they'd leak into juceaide's x64 build), add them explicitly.
# Use STANDARD_LIBRARIES so they appear AFTER objects in the link command
# (GNU ld is order-sensitive — libs before objects are discarded).
set(CMAKE_CXX_STANDARD_LIBRARIES "${CMAKE_CXX_STANDARD_LIBRARIES} -lfreetype -lfontconfig")
set(CMAKE_C_STANDARD_LIBRARIES "${CMAKE_C_STANDARD_LIBRARIES} -lfreetype -lfontconfig")
