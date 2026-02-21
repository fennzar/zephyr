#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/../lib/common.sh"

name="${1:-}"

# No arg or --list: show available snapshots
if [[ -z "$name" || "$name" == "--list" ]]; then
    echo "Available snapshots:"
    echo ""
    if [[ -d "$SNAPSHOT_DIR" ]]; then
        found=0
        for meta in "$SNAPSHOT_DIR"/*.json; do
            [[ -f "$meta" ]] || continue
            found=1
            python3 -c "
import json
with open('$meta') as f:
    m = json.load(f)
print(f'  {m[\"name\"]:15s} height={m[\"height\"]}  {m[\"timestamp\"]}')
" 2>/dev/null
        done
        if [[ "$found" -eq 0 ]]; then
            echo "  (none)"
        fi
    else
        echo "  (none)"
    fi
    echo ""
    echo "Usage: run.sh restore <name>"
    exit 0
fi

SNAPSHOT_FILE="$SNAPSHOT_DIR/$name.tar.gz"
SNAPSHOT_META="$SNAPSHOT_DIR/$name.json"

if [[ ! -f "$SNAPSHOT_FILE" ]]; then
    echo "Error: Snapshot '$name' not found at $SNAPSHOT_FILE"
    echo "Run 'run.sh restore --list' to see available snapshots."
    exit 1
fi

# Check build exists
if [[ ! -x "$BUILD_DIR/bin/zephyrd" ]]; then
    echo "Error: Devnet binaries not found at $BUILD_DIR/bin/"
    echo "Run 'run.sh build' first."
    exit 1
fi

# Read metadata
oracle_spot=$(python3 -c "import json; print(json.load(open('$SNAPSHOT_META'))['oracle_spot'])" 2>/dev/null || echo "$DEFAULT_SPOT")
snap_height=$(python3 -c "import json; print(json.load(open('$SNAPSHOT_META'))['height'])" 2>/dev/null || echo "?")

echo "=== Restoring snapshot: $name (height $snap_height) ==="
echo ""

# Stop any running devnet
"$SCRIPT_DIR/stop.sh" 2>/dev/null || true

# Extract snapshot
echo "Extracting snapshot..."
rm -rf "$DATA_DIR"
mkdir -p "$DATA_DIR"
tar -xzf "$SNAPSHOT_FILE" -C /tmp

# Generate Procfile and start overmind
_generate_procfile
echo "Starting processes..."
overmind start -D -f "$DATA_DIR/Procfile" -s "$OVERMIND_SOCK"
sleep 2

# Set oracle price from snapshot
echo "Setting oracle price..."
curl -s -X POST "http://127.0.0.1:$ORACLE_PORT/set-price" \
    -H 'Content-Type: application/json' \
    -d "{\"spot\": $oracle_spot}" > /dev/null

# Wait for nodes
echo ""
wait_for_rpc $RPC_PORT1 "node1" 30
wait_for_rpc $RPC_PORT2 "node2" 30
wait_for_sync $RPC_PORT1 "node1" 60
wait_for_sync $RPC_PORT2 "node2" 60

# Wait for wallet-rpc instances
echo ""
echo "--- Waiting for wallet-rpc instances ---"
wait_for_wallet_rpc $GOV_WALLET_RPC_PORT "gov" 15
wait_for_wallet_rpc $MINER_WALLET_RPC_PORT "miner" 15
wait_for_wallet_rpc $TEST_WALLET_RPC_PORT "test" 15

# Open existing wallets
echo ""
echo "--- Opening wallets ---"
rpc_call $GOV_WALLET_RPC_PORT "open_wallet" '{"filename":"gov","password":""}' > /dev/null 2>&1
echo "  Gov wallet opened"
rpc_call $MINER_WALLET_RPC_PORT "open_wallet" '{"filename":"miner","password":""}' > /dev/null 2>&1
echo "  Miner wallet opened"
rpc_call $TEST_WALLET_RPC_PORT "open_wallet" '{"filename":"test","password":""}' > /dev/null 2>&1
echo "  Test wallet opened"

# Rescan wallets to sync with restored chain
echo ""
echo "--- Rescanning wallets ---"
_rescan_all_wallets

# Start mining
echo ""
echo "--- Starting mining ---"
_restart_mining

# Show status
echo ""
"$SCRIPT_DIR/status.sh"
