#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/../lib/common.sh"

ZEPHYR_CLI="$REPO_ROOT/tools/zephyr-cli/cli"

if [[ ! -x "$ZEPHYR_CLI" ]]; then
    echo "Error: zephyr-cli not found at $ZEPHYR_CLI"
    exit 1
fi

mode="${1:-}"

# If no arg: check for snapshots and show menu
if [[ -z "$mode" ]]; then
    has_snapshots=0
    if [[ -d "$SNAPSHOT_DIR" ]]; then
        for f in "$SNAPSHOT_DIR"/*.tar.gz; do
            [[ -f "$f" ]] && has_snapshots=1 && break
        done
    fi

    if [[ "$has_snapshots" -eq 1 ]]; then
        echo "Saved snapshots found:"
        echo ""
        for meta in "$SNAPSHOT_DIR"/*.json; do
            [[ -f "$meta" ]] || continue
            python3 -c "
import json
with open('$meta') as f:
    m = json.load(f)
print(f'  {m[\"name\"]:15s} height={m[\"height\"]}  {m[\"timestamp\"]}')
" 2>/dev/null
        done
        echo ""
        echo "Usage:"
        echo "  run.sh start new           Start a fresh chain from scratch (~5 min)"
        echo "  run.sh start <name>        Restore from a saved snapshot (~30 sec)"
        echo ""
        echo "Example: run.sh start default"
        exit 0
    else
        mode="new"
    fi
fi

# Restore from snapshot
if [[ "$mode" != "new" ]]; then
    exec "$SCRIPT_DIR/restore.sh" "$mode"
fi

# ─── Fresh start ──────────────────────────────────────────────────────────────

echo "=== Starting DEVNET (fresh) ==="
echo ""

# Clean slate
"$SCRIPT_DIR/stop.sh" 2>/dev/null || true
echo "Cleaning data directory..."
rm -rf "$DATA_DIR"
mkdir -p "$NODE1_DATA" "$NODE2_DATA" "$WALLET_DIR" "$DATA_DIR/ringdb"

# 1. Generate Procfile with resolved paths
_generate_procfile

# 2. Start all processes via overmind
echo "--- Starting all processes via overmind ---"
overmind start -D -f "$DATA_DIR/Procfile" -s "$OVERMIND_SOCK"
sleep 2

# 3. Run devnet init (sets oracle, creates wallets, mines, runs setup-state, checkpoints)
echo ""
echo "--- Running devnet init via CLI ---"
"$ZEPHYR_CLI" devnet init \
    --oracle-price 1.50 \
    --mode "${DEVNET_MODE:-custom}" \
    --checkpoint-file "$CHECKPOINT_FILE"

# 4. Auto-save snapshot (overwrite previous "default" if exists)
echo ""
echo "--- Auto-saving snapshot for fast restore ---"
rm -f "$SNAPSHOT_DIR/default.tar.gz" "$SNAPSHOT_DIR/default.json"
"$SCRIPT_DIR/save.sh" "default"

# 5. Print summary
echo ""
"$SCRIPT_DIR/status.sh"
