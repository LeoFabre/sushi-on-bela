# vcpkg triplet — ARM64 Linux cross-compilation for Elk Audio OS
# (PocketBeagle2 / Raspberry Pi 4, aarch64)

set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CRT_LINKAGE          dynamic)
set(VCPKG_LIBRARY_LINKAGE      static)
set(VCPKG_CMAKE_SYSTEM_NAME    Linux)

set(VCPKG_CHAINLOAD_TOOLCHAIN_FILE /opt/toolchain-aarch64-elk.cmake)

set(VCPKG_SYSROOT "")

set(VCPKG_CXX_FLAGS "-std=c++20")
set(VCPKG_C_FLAGS   "")
