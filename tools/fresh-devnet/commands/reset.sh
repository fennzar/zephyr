#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

ZEPHYR_CLI="$REPO_ROOT/tools/zephyr-cli/cli"

if [[ ! -x "$ZEPHYR_CLI" ]]; then
    echo "Error: zephyr-cli not found at $ZEPHYR_CLI"
    exit 1
fi

mode=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --status)  mode="status"; shift ;;
        --force)   mode="force"; shift ;;
        --recover) mode="recover"; shift ;;
        *)
            echo "Usage: run.sh reset [--status|--force|--recover]"
            echo ""
            echo "Options:"
            echo "  --status   Show current height vs checkpoint height"
            echo "  --force    Skip confirmations and continue on non-fatal errors"
            echo "  --recover  Recovery mode: rescan wallets + restart mining only"
            exit 1
            ;;
    esac
done

# Check node is running
current_height=$("$ZEPHYR_CLI" height 2>/dev/null) || {
    echo "Error: Node1 not responding on port $RPC_PORT1"
    echo "Start devnet first: run.sh start"
    exit 1
}

# Check checkpoint exists
if [[ ! -f "$CHECKPOINT_FILE" ]]; then
    echo "Error: No checkpoint found at $CHECKPOINT_FILE"
    echo "Run 'run.sh checkpoint' to save one, or 'run.sh start' for a fresh chain."
    exit 1
fi
checkpoint_height=$(cat "$CHECKPOINT_FILE")

# --status: just show info
if [[ "$mode" == "status" ]]; then
    echo "=== DEVNET Reset Status ==="
    echo ""
    echo "Current height:    $current_height"
    echo "Checkpoint height: $checkpoint_height"
    echo "Blocks to pop:     $((current_height - checkpoint_height))"
    echo ""
    echo "Checkpoint file: $CHECKPOINT_FILE"
    exit 0
fi

# --recover: skip block pop, just fix wallets and mining
if [[ "$mode" == "recover" ]]; then
    echo "=== DEVNET Recovery Mode ==="
    echo ""
    echo "Skipping block pop, recovering wallet and mining state..."

    echo "Stopping mining..."
    "$ZEPHYR_CLI" mine stop 2>/dev/null || true
    sleep 2

    echo "Rescanning wallets..."
    "$ZEPHYR_CLI" rescan all

    echo "Restarting mining..."
    "$ZEPHYR_CLI" mine start

    echo ""
    echo "Recovery complete. Current height: $current_height"
    exit 0
fi

# Normal reset
echo "=== DEVNET Reset to Checkpoint ==="
echo ""
echo "Current height:    $current_height"
echo "Checkpoint height: $checkpoint_height"

if [[ "$current_height" -le "$checkpoint_height" ]]; then
    echo "Nothing to reset (current <= checkpoint)."
    exit 0
fi

blocks_to_pop=$((current_height - checkpoint_height))
echo "Blocks to pop:     $blocks_to_pop"
echo ""

# Step 1: Stop mining
echo "Stopping mining..."
"$ZEPHYR_CLI" mine stop 2>/dev/null || true
sleep 1

# Step 2: Pop blocks on both nodes
echo "Popping $blocks_to_pop blocks on node1..."
"$ZEPHYR_CLI" pop "$blocks_to_pop" || {
    if [[ "$mode" != "force" ]]; then
        echo "Use --force to continue, or --recover to fix wallet state"
        exit 1
    fi
    echo "Force mode: continuing despite error..."
}

# Pop node2 separately (CLI only knows node1)
echo "Popping $blocks_to_pop blocks on node2..."
rpc_other "$RPC_PORT2" "pop_blocks" "{\"nblocks\":$blocks_to_pop}" >/dev/null 2>&1 || \
    echo "  WARNING: Failed to pop blocks on node2 (may need sync)"

# Wait for nodes to sync
echo "Waiting for nodes to sync..."
sleep 3

# Step 3: Rescan wallets
echo "Rescanning wallets..."
"$ZEPHYR_CLI" rescan all

# Step 4: Restart mining
echo "Restarting mining..."
"$ZEPHYR_CLI" mine start

# Summary
final_height=$("$ZEPHYR_CLI" height)
echo ""
echo "=== Reset Complete ==="
echo "Final height: $final_height (checkpoint: $checkpoint_height)"
echo ""
echo "Ready for testing. To reset again: run.sh reset"
