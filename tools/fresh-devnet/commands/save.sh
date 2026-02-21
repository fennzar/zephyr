#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

name="${1:-default}"
SNAPSHOT_FILE="$SNAPSHOT_DIR/$name.tar.gz"
SNAPSHOT_META="$SNAPSHOT_DIR/$name.json"

# Check devnet is running
if ! rpc_call "$RPC_PORT1" "get_info" 2>/dev/null | grep -q '"status"'; then
    echo "Error: Devnet not running. Start it first: run.sh start"
    exit 1
fi

# Check for existing snapshot
if [[ -f "$SNAPSHOT_FILE" ]]; then
    echo "Snapshot '$name' already exists ($SNAPSHOT_FILE)"
    echo "Delete it first or choose a different name."
    exit 1
fi

# Stop mining for a clean state
echo "Stopping mining..."
rpc_other "$RPC_PORT1" "stop_mining" > /dev/null 2>&1 || true
sleep 2

# Capture current state
height=$(get_height)
oracle_spot=$(curl -s --max-time 2 "http://127.0.0.1:$ORACLE_PORT/status" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['spot'])" 2>/dev/null \
    || echo "$DEFAULT_SPOT")

# Save metadata
mkdir -p "$SNAPSHOT_DIR"
python3 -c "
import json
info = {
    'name': '$name',
    'height': $height,
    'oracle_spot': $oracle_spot,
    'timestamp': '$(date -Iseconds)'
}
print(json.dumps(info, indent=2))
" > "$SNAPSHOT_META"

# Tar up data (excluding runtime files)
echo "Saving snapshot '$name' at height $height..."
tar_args=(
    -czf "$SNAPSHOT_FILE"
    -C /tmp
    zephyr-devnet/node1
    zephyr-devnet/node2
    zephyr-devnet/wallets
    zephyr-devnet/ringdb
)
# Include checkpoint files if they exist
[[ -f "$CHECKPOINT_FILE" ]] && tar_args+=( zephyr-devnet/checkpoint_height )
[[ -f "$CHECKPOINT_INFO_FILE" ]] && tar_args+=( zephyr-devnet/checkpoint_info.json )

tar "${tar_args[@]}"

# Restart mining
echo "Restarting mining..."
_restart_mining

size=$(du -h "$SNAPSHOT_FILE" | cut -f1)
echo ""
echo "Snapshot saved:"
echo "  Name:   $name"
echo "  Height: $height"
echo "  File:   $SNAPSHOT_FILE ($size)"
