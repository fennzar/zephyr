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

# Cap parallelism: 1 job per 2GB RAM, minimum 1, respect JOBS env override
if [ -n "${JOBS:-}" ]; then
    NPROC="$JOBS"
else
    MEM_GB=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo "4")
    NPROC=$((MEM_GB / 2))
    [ "$NPROC" -lt 1 ] && NPROC=1
    CPU_COUNT=$(nproc 2>/dev/null || echo "2")
    [ "$NPROC" -gt "$CPU_COUNT" ] && NPROC="$CPU_COUNT"
fi
echo "  Parallel jobs: $NPROC (override with JOBS=N)"
make -j"$NPROC" daemon simplewallet wallet_rpc_server
echo "=== Build complete ($MODE mode) ==="
