# elk-crossbuild — cross-compilation image for Sushi on Bela (PocketBeagle2)
# Based on Debian 12 (Bookworm) to match Bela's glibc 2.36.
FROM debian:bookworm

ENV DEBIAN_FRONTEND=noninteractive

RUN dpkg --add-architecture arm64 \
    && apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    gcc-aarch64-linux-gnu \
    g++-aarch64-linux-gnu \
    ninja-build \
    git \
    curl \
    ca-certificates \
    zip unzip tar \
    pkg-config \
    python3 python3-pip python3-venv \
    libasound2-dev:arm64 \
    libfreetype6:arm64 \
    libfontconfig1:arm64 \
    libcurl4-openssl-dev:arm64 \
    libgtk-3-dev:arm64 \
    libwebkit2gtk-4.0-dev:arm64 \
    libgl-dev:arm64 \
    mesa-common-dev:arm64 \
    shared-mime-info \
    x11proto-dev \
    libx11-dev:arm64 libxrandr-dev:arm64 libxinerama-dev:arm64 libxcursor-dev:arm64 libxext-dev:arm64 \
    libssl-dev \
    autoconf autoconf-archive automake libtool \
    libx11-dev libxrandr-dev libxinerama-dev libxcursor-dev libxext-dev \
    libfreetype6-dev libfontconfig1-dev \
    libgl-dev mesa-common-dev \
    libgtk-3-dev \
    libcurl4-openssl-dev \
    libasound2-dev \
    && rm -rf /var/lib/apt/lists/*

# ARM64 freetype/fontconfig: create -dev symlinks for cross-linker.
# Do NOT add .pc files — they leak into juceaide's x64 build via PKG_CONFIG_PATH.
RUN ln -sf libfreetype.so.6 /usr/lib/aarch64-linux-gnu/libfreetype.so \
    && ln -sf libfontconfig.so.1 /usr/lib/aarch64-linux-gnu/libfontconfig.so

# Freetype include path: JUCE's juceaide needs ft2build.h and the freetype/
# directory in the standard include path for the native (x64) build.
RUN ln -sf /usr/include/freetype2/ft2build.h /usr/include/ft2build.h \
    && ln -sf /usr/include/freetype2/freetype /usr/include/freetype

# CMake 3.28+ (Debian Bookworm only ships 3.25)
RUN curl -fsSL https://github.com/Kitware/CMake/releases/download/v3.30.2/cmake-3.30.2-linux-x86_64.tar.gz \
    | tar xz -C /usr/local --strip-components=1

# Meson (needed by some vcpkg ports)
RUN pip3 install --break-system-packages meson

# vcpkg
ENV VCPKG_ROOT=/opt/vcpkg
RUN git clone --depth 1 https://github.com/microsoft/vcpkg.git ${VCPKG_ROOT} \
    && ${VCPKG_ROOT}/bootstrap-vcpkg.sh -disableMetrics

# vcpkg triplet for ARM64 Elk
COPY triplets/arm64-elk-linux.cmake ${VCPKG_ROOT}/triplets/community/

# Toolchain file
COPY toolchain-aarch64-elk.cmake /opt/toolchain-aarch64-elk.cmake

# Meson cross file
COPY meson-aarch64-cross.ini /opt/meson-aarch64-cross.ini

# Overlay ports (patched vcpkg ports for cross-compilation fixes)
COPY overlay-ports/ /opt/overlay-ports/

# Build scripts
COPY scripts/ /opt/scripts/
RUN chmod +x /opt/scripts/*.sh

# Elk sysroot placeholder
RUN mkdir -p /opt/elk-sysroot/usr/lib

# Twine source (will be symlinked if sushi submodule is missing)
# Cloned separately so it doesn't depend on the sushi mount
ARG TWINE_REF=main
RUN git clone --depth 1 --branch ${TWINE_REF} --recurse-submodules \
    https://github.com/elk-audio/twine.git /opt/twine-src || true

ENV VCPKG_TARGET_TRIPLET=arm64-elk-linux
ENV VCPKG_HOST_TRIPLET=x64-linux

WORKDIR /workspace
SHELL ["/bin/bash", "-c"]
CMD ["/bin/bash"]
