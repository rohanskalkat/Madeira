#!/bin/bash
# Configure (first time) and build the FEXCore static libraries the app links
# (FEX/build-ios/FEXCore/Source/*.a and External/*). Options mirror the
# development build's CMakeCache.
set -eu
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
B="$R/FEX/build-ios"
if [ ! -f "$B/CMakeCache.txt" ]; then
    # CMAKE_SYSTEM_PROCESSOR: CMake leaves it empty when cross-compiling for iOS,
    # and FEX's architecture check rejects an empty processor type.
    # TUNE_CPU=none: the default (native) probes the build machine's /proc/cpuinfo,
    # which is wrong for a cross build and does not exist on macOS.
    # ios_host_shims.h: supplies two diagnostic counters the fork reads but only
    # defines for its Windows modules (see the header).
    cmake -S "$R/FEX" -B "$B" -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_SYSTEM_PROCESSOR=aarch64 -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_TESTING=OFF -DBUILD_THUNKS=OFF -DBUILD_FEXCONFIG=OFF -DBUILD_FEX_LINUX_TESTS=OFF \
        -DTUNE_CPU=none \
        -DCMAKE_CXX_FLAGS="-include $R/build/fex-ios/ios_host_shims.h" \
        -DENABLE_FEX_ALLOCATOR=OFF -DENABLE_ASSERTIONS=OFF -DENABLE_CLANG_THUNKS=ON -DENABLE_CCACHE=ON
fi
cmake --build "$B" --target FEXCore FEXCore_Base JemallocLibs
ls "$B/FEXCore/Source/"*.a
