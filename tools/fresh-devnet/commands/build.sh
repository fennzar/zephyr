#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

echo "=== Building devnet binaries in $BUILD_DIR ==="
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
cmake "$REPO_ROOT" -DCMAKE_BUILD_TYPE=Release
make -j$(nproc) daemon simplewallet wallet_rpc_server
echo "=== Build complete ==="
