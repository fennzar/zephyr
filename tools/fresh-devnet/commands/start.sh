#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/../lib/common.sh"

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

# 3. Set initial oracle price
ZEPHYR_CLI="$REPO_ROOT/tools/zephyr-cli/cli"
echo ""
echo "--- Setting initial oracle price (\$1.50) ---"
if [[ -x "$ZEPHYR_CLI" ]]; then
    "$ZEPHYR_CLI" price 1.50
else
    curl -s -X POST "http://127.0.0.1:$ORACLE_PORT/set-price" \
        -H 'Content-Type: application/json' \
        -d "{\"spot\": $DEFAULT_SPOT}" > /dev/null
fi

# 4. Wait for nodes to be ready
echo ""
wait_for_rpc $RPC_PORT1 "node1" 30
wait_for_rpc $RPC_PORT2 "node2" 30
wait_for_sync $RPC_PORT1 "node1" 30
wait_for_sync $RPC_PORT2 "node2" 30

# 5. Wait for wallet-rpc instances
echo ""
echo "--- Waiting for wallet-rpc instances ---"
wait_for_wallet_rpc $GOV_WALLET_RPC_PORT "gov" 15
wait_for_wallet_rpc $MINER_WALLET_RPC_PORT "miner" 15
wait_for_wallet_rpc $TEST_WALLET_RPC_PORT "test" 15

# 6. Create/restore wallets via RPC BEFORE mining starts
#    This ensures the gov wallet starts at height 0 and incrementally scans
#    all new blocks (including block 1 with the governance output).
echo ""
echo "--- Restoring governance wallet from keys ---"
gov_result=$(rpc_call $GOV_WALLET_RPC_PORT "generate_from_keys" "{
    \"filename\": \"gov\",
    \"address\": \"$GOV_ADDRESS\",
    \"spendkey\": \"$GOV_SPEND_KEY\",
    \"viewkey\": \"$GOV_VIEW_KEY\",
    \"password\": \"\",
    \"restore_height\": 0
}")
echo "Gov wallet: $(echo "$gov_result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('result',{}).get('address','ERROR'))" 2>/dev/null)"

echo "--- Creating miner wallet ---"
rpc_call $MINER_WALLET_RPC_PORT "create_wallet" '{"filename":"miner","password":"","language":"English"}' > /dev/null 2>&1 || true
sleep 1
echo "Miner wallet: $("$ZEPHYR_CLI" address miner 2>/dev/null || echo "UNKNOWN")"

echo "--- Creating test wallet ---"
rpc_call $TEST_WALLET_RPC_PORT "create_wallet" '{"filename":"test","password":"","language":"English"}' > /dev/null 2>&1 || true
sleep 1
echo "Test wallet: $("$ZEPHYR_CLI" address test 2>/dev/null || echo "UNKNOWN")"

# 7. Start mining to miner wallet on node1
echo ""
echo "--- Starting mining on node1 (2 threads) ---"
"$ZEPHYR_CLI" mine start --wallet miner --threads 2

# 8. Wait for governance funds to unlock (60 blocks + some margin)
echo ""
"$ZEPHYR_CLI" wait 70

# 9. Run state setup
echo ""
"$SCRIPT_DIR/setup-state.sh"

# 10. Auto-checkpoint for fast reset later
echo ""
echo "--- Saving checkpoint for fast reset ---"
"$SCRIPT_DIR/checkpoint.sh"

# 11. Auto-save snapshot (overwrite previous "default" if exists)
echo ""
echo "--- Auto-saving snapshot for fast restore ---"
rm -f "$SNAPSHOT_DIR/default.tar.gz" "$SNAPSHOT_DIR/default.json"
"$SCRIPT_DIR/save.sh" "default"

# 12. Print summary
echo ""
"$SCRIPT_DIR/status.sh"
