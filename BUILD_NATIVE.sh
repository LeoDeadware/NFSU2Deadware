#!/bin/bash
# Native macOS build (Metal only): community/build-metal/nfsu2_recomp. Homebrew cmake/ninja/sdl2-compat are
# build-time tools only; the app carries SDL in Contents/Frameworks (tools/install_app.sh). No Vulkan,
# glslang, SPIRV-Tools or OpenSSL. NFSU2_VULKAN=1: the old Vulkan+Metal build in community/build-macos.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
export PATH="/opt/homebrew/bin:$PATH"
if [[ "${NFSU2_VULKAN:-0}" == 1 ]]; then
  B="$ROOT/community/build-macos"
  cmake -S "$ROOT/community" -B "$B" -G Ninja -DCMAKE_BUILD_TYPE=Release -DNFSU2_GEN_DIR="$ROOT/community/gen" \
    -DNFSU2_VULKAN=ON -DNFSU2_METAL=ON -DNFSU2_GEN_OPT=-O2 -DXBOXRECOMP_D3D8_NULL=ON \
    -DCMAKE_PREFIX_PATH="$ROOT/deps;/opt/homebrew" -DVulkan_INCLUDE_DIR="$ROOT/deps/include" \
    -DVulkan_LIBRARY="$ROOT/deps/lib/libvulkan.dylib" -DOPENSSL_ROOT_DIR=/opt/homebrew/opt/openssl
else
  B="$ROOT/community/build-metal"
  cmake -S "$ROOT/community" -B "$B" -G Ninja -DCMAKE_BUILD_TYPE=Release -DNFSU2_GEN_DIR="$ROOT/community/gen" \
    -DNFSU2_VULKAN=OFF -DNFSU2_METAL=ON -DNFSU2_GEN_OPT=-O2 -DXBOXRECOMP_D3D8_NULL=ON \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 -DCMAKE_PREFIX_PATH=/opt/homebrew
fi
cmake --build "$B" -j"${JOBS:-2}"
otool -L "$B/nfsu2_recomp" | awk 'NR>1{print "  " $1}'
