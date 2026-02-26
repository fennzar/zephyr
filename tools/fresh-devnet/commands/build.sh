#!/bin/bash
set -euo pipefail

MODE="${1:-custom}"  # custom | mirror

source "$(dirname "$0")/../lib/common.sh"

# Override BUILD_DIR for mirror mode
if [ "$MODE" = "mirror" ]; then
    BUILD_DIR="$REPO_ROOT/build/devnet-mirror"
    CMAKE_FLAGS="-DDEVNET_MIRROR_SUPPLY=ON"
    echo "=== Building MIRROR devnet binaries in $BUILD_DIR ==="
else
    CMAKE_FLAGS=""
    echo "=== Building devnet binaries in $BUILD_DIR ==="
fi

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
cmake "$REPO_ROOT" -DCMAKE_BUILD_TYPE=Release $CMAKE_FLAGS
make -j$(nproc) daemon simplewallet wallet_rpc_server
echo "=== Build complete ($MODE mode) ==="
