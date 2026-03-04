#!/bin/bash
# Unified devnet lifecycle dispatcher — native (Overmind) and Docker modes.
#
# Usage:
#   tools/devnet.sh start|init|stop|reset|delete|status [--docker]
#
# Mode detection:
#   DEVNET_DOCKER=1 or --docker → Docker mode
#   Default: native (Overmind)
#
# Docker consumers can set DC_ARGS to override the compose file chain:
#   DC_ARGS="-f docker/compose.yml -f compose.bridge.yml" tools/devnet.sh init
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEVNET_DIR="$REPO_ROOT/tools/fresh-devnet"

# ─── Mode detection ──────────────────────────────────────────────────────────

DOCKER_MODE="${DEVNET_DOCKER:-0}"

# Parse --docker flag from args
args=()
for arg in "$@"; do
    if [[ "$arg" == "--docker" ]]; then
        DOCKER_MODE=1
    else
        args+=("$arg")
    fi
done
set -- "${args[@]+"${args[@]}"}"

COMMAND="${1:-}"
shift || true

# ─── Shared helpers ──────────────────────────────────────────────────────────

source "$DEVNET_DIR/lib/common.sh"

ZEPHYR_CLI="$REPO_ROOT/tools/zephyr-cli/cli"

dc() {
    if [ -n "${DC_CMD:-}" ]; then
        $DC_CMD "$@"
    else
        local dc_args="${DC_ARGS:--f $REPO_ROOT/docker/compose.yml}"
        docker compose $dc_args "$@"
    fi
}

_parse_docker_flags() {
    SNAPSHOT_DIR=""
    CHECKPOINT_HEIGHT=""
    HARD_MODE=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --snapshot-dir) SNAPSHOT_DIR="$2"; shift 2 ;;
            --checkpoint)   CHECKPOINT_HEIGHT="$2"; shift 2 ;;
            --hard)         HARD_MODE=true; shift ;;
            *) shift ;;
        esac
    done
}

genesis_guard() {
    local height
    height=$(get_height "$RPC_PORT1" 2>/dev/null || echo "0")
    if [ "$height" -gt 1 ]; then
        echo "Error: Chain already at height $height (expected genesis)."
        echo "Run 'make devnet-delete' first, then 'make devnet-init'."
        exit 1
    fi
}

# ─── Native mode commands ────────────────────────────────────────────────────

_ensure_binaries() {
    local bin_dir="$BUILD_DIR/bin"
    if [ ! -f "$bin_dir/zephyrd" ] || [ ! -f "$bin_dir/zephyr-wallet-rpc" ]; then
        echo "--- Zephyr devnet binaries not found, building... ---"
        "$DEVNET_DIR/commands/build.sh" "${DEVNET_MODE:-custom}"
        echo ""
    fi
}

native_start() {
    echo "=== Starting devnet (native) ==="
    echo ""

    _ensure_binaries

    # Create data dirs if needed
    mkdir -p "$NODE1_DATA" "$NODE2_DATA" "$WALLET_DIR" "$DATA_DIR/ringdb"

    # Generate Procfile and start overmind (if not already running)
    if overmind_running; then
        echo "Overmind already running"
    else
        _generate_procfile
        echo "--- Starting all processes via overmind ---"
        overmind start -D -f "$DATA_DIR/Procfile" -s "$OVERMIND_SOCK"
        sleep 2
    fi

    # Create wallets (no mining/minting)
    echo ""
    echo "--- Creating wallets (wallets-only) ---"
    "$ZEPHYR_CLI" devnet init \
        --oracle-price "${ORACLE_PRICE:-1.50}" \
        --mode "${DEVNET_MODE:-custom}" \
        --wallets-only

    echo ""
    echo "=== Devnet running ==="
}

native_init() {
    echo "=== Devnet Init (native) — full bootstrap ==="
    echo ""

    _ensure_binaries
    genesis_guard

    # Start if not already running
    if ! overmind_running; then
        mkdir -p "$NODE1_DATA" "$NODE2_DATA" "$WALLET_DIR" "$DATA_DIR/ringdb"
        _generate_procfile
        echo "--- Starting all processes via overmind ---"
        overmind start -D -f "$DATA_DIR/Procfile" -s "$OVERMIND_SOCK"
        sleep 2
    fi

    # Full bootstrap
    echo ""
    echo "--- Running full devnet init ---"
    "$ZEPHYR_CLI" devnet init \
        --oracle-price "${ORACLE_PRICE:-1.50}" \
        --mode "${DEVNET_MODE:-custom}" \
        --checkpoint-file "$CHECKPOINT_FILE"

    echo ""
    echo "=== Devnet init complete ==="
}

native_stop() {
    "$DEVNET_DIR/commands/stop.sh"
}

native_reset() {
    "$DEVNET_DIR/commands/reset.sh" "$@"
}

native_delete() {
    echo "=== Deleting devnet data (native) ==="

    # Stop first
    "$DEVNET_DIR/commands/stop.sh" 2>/dev/null || true

    echo "Removing data directory: $DATA_DIR"
    rm -rf "$DATA_DIR"

    echo "=== Devnet data deleted ==="
}

native_status() {
    "$DEVNET_DIR/commands/status.sh"
}

# ─── Docker mode commands ────────────────────────────────────────────────────

docker_start() {
    echo "=== Starting devnet (Docker) ==="
    echo ""

    _ensure_binaries
    dc up -d
    echo ""

    echo "--- Creating wallets (wallets-only) ---"
    WALLETS_ONLY=true dc --profile init run --rm devnet-init

    echo ""
    echo "=== Devnet running (Docker) ==="
}

docker_init() {
    _parse_docker_flags "$@"

    echo "=== Devnet Init (Docker) — full bootstrap ==="
    echo ""

    _ensure_binaries

    # Start services if not running
    if ! dc ps --status running -q zephyr-node1 2>/dev/null | grep -q .; then
        dc up -d
        echo ""
    fi

    genesis_guard

    echo "--- Running full devnet init ---"
    dc --profile init run --rm devnet-init

    # Save LMDB snapshots if --snapshot-dir was provided
    if [ -n "$SNAPSHOT_DIR" ]; then
        echo ""
        echo "--- Saving LMDB snapshots ---"
        dc stop zephyr-node1 zephyr-node2
        docker run --rm -v zephyr-node1-data:/data alpine \
            tar czf - -C /data --exclude='lmdb/lock.mdb' lmdb > "$SNAPSHOT_DIR/node1-lmdb.tar.gz"
        docker run --rm -v zephyr-node2-data:/data alpine \
            tar czf - -C /data --exclude='lmdb/lock.mdb' lmdb > "$SNAPSHOT_DIR/node2-lmdb.tar.gz"
        echo "  Snapshots saved ($(du -sh "$SNAPSHOT_DIR/" | cut -f1))"
    fi

    echo ""
    echo "=== Devnet init complete (Docker) ==="
}

docker_stop() {
    echo "=== Stopping devnet (Docker) ==="
    dc down
    echo "=== Stopped ==="
}

docker_reset() {
    _parse_docker_flags "$@"

    if [ "$HARD_MODE" = true ]; then
        _docker_reset_hard
    else
        _docker_reset_normal
    fi
}

_docker_reset_normal() {
    echo "=== Resetting devnet (Docker) ==="
    echo ""

    if [ -z "$CHECKPOINT_HEIGHT" ]; then
        # No checkpoint provided — read from Docker volume (standalone mode)
        CHECKPOINT_HEIGHT=$(dc exec -T devnet-init cat /checkpoint/height 2>/dev/null || echo "")
        if [ -z "$CHECKPOINT_HEIGHT" ]; then
            echo "Error: No checkpoint found (pass --checkpoint HEIGHT or save one first)"
            exit 1
        fi
    fi

    local current_height
    current_height=$(get_height "$RPC_PORT1" 2>/dev/null || echo "0")
    if [ "$current_height" -eq 0 ]; then
        echo "Error: Node not reachable"
        exit 1
    fi

    echo "Current height:    $current_height"
    echo "Checkpoint height: $CHECKPOINT_HEIGHT"

    if [ "$current_height" -le "$CHECKPOINT_HEIGHT" ]; then
        echo "Nothing to reset (current <= checkpoint)."
        return
    fi

    local blocks_to_pop=$((current_height - CHECKPOINT_HEIGHT))
    echo "Blocks to pop:     $blocks_to_pop"
    echo ""

    # 1. Stop mining
    echo "Stopping mining..."
    rpc_other "$RPC_PORT1" "stop_mining" > /dev/null 2>&1 || true
    sleep 1

    # 2. Close base wallets
    echo "Closing base wallets..."
    for port in "$GOV_WALLET_RPC_PORT" "$MINER_WALLET_RPC_PORT" "$TEST_WALLET_RPC_PORT"; do
        rpc_call "$port" "close_wallet" > /dev/null 2>&1 || true
    done

    # 3. Pop blocks on both nodes
    echo "Popping $blocks_to_pop blocks..."
    rpc_other "$RPC_PORT1" "pop_blocks" "{\"nblocks\":$blocks_to_pop}" > /dev/null 2>&1
    rpc_other "$RPC_PORT2" "pop_blocks" "{\"nblocks\":$blocks_to_pop}" > /dev/null 2>&1 || true
    sleep 2

    # 4. Clear ringdb
    echo "Clearing shared ring database..."
    dc exec -T wallet-gov sh -c 'rm -f /data/ringdb/data.mdb /data/ringdb/lock.mdb' 2>/dev/null || true

    # 5. Restart node1 (force resync after pop_blocks)
    echo "Restarting node1..."
    docker restart zephyr-node1 > /dev/null 2>&1
    sleep 5

    # 6. Wait for sync
    wait_for_sync "$RPC_PORT1" "node1" 30

    # 7. Reopen base wallets
    echo "Reopening base wallets..."
    for name_port in "gov:$GOV_WALLET_RPC_PORT" "miner:$MINER_WALLET_RPC_PORT" "test:$TEST_WALLET_RPC_PORT"; do
        local name="${name_port%%:*}"
        local port="${name_port##*:}"
        rpc_call "$port" "open_wallet" "{\"filename\":\"$name\",\"password\":\"\"}" > /dev/null 2>&1 || \
            echo "  WARNING: Failed to open $name wallet"
    done

    # 8. Rescan wallets
    echo "Rescanning wallets..."
    _rescan_all_wallets
    sleep 2

    # 9. Flush txpool
    echo "Flushing transaction pool..."
    rpc_other "$RPC_PORT1" "flush_txpool" > /dev/null 2>&1 || true

    # 10. Mine warmup blocks
    echo "Mining warm-up blocks..."
    _restart_mining
    sleep 10
    rpc_other "$RPC_PORT1" "stop_mining" > /dev/null 2>&1 || true
    sleep 1

    # 11. Final rescan
    echo "Final rescan..."
    _rescan_all_wallets
    sleep 2

    echo ""
    local final_height
    final_height=$(get_height "$RPC_PORT1")
    echo "=== Reset complete (height: $final_height) ==="
}

_docker_reset_hard() {
    echo "=== Resetting devnet — hard (Docker) ==="
    echo ""

    if [ -z "$SNAPSHOT_DIR" ]; then
        echo "Error: --snapshot-dir required for hard reset"
        exit 1
    fi
    if [ ! -f "$SNAPSHOT_DIR/node1-lmdb.tar.gz" ]; then
        echo "Error: Chain snapshots not found at $SNAPSHOT_DIR"
        exit 1
    fi

    # 1. Close base wallets
    echo "Closing base wallets..."
    for port in "$GOV_WALLET_RPC_PORT" "$MINER_WALLET_RPC_PORT" "$TEST_WALLET_RPC_PORT"; do
        rpc_call "$port" "close_wallet" > /dev/null 2>&1 || true
    done

    # 2. Stop nodes
    echo "Stopping nodes..."
    dc stop zephyr-node1 zephyr-node2 2>/dev/null

    # 3. Restore LMDB from snapshots
    echo "Restoring LMDB from snapshots..."
    docker run --rm -v zephyr-node1-data:/data -v "$SNAPSHOT_DIR:/snap:ro" alpine \
        sh -c 'rm -rf /data/lmdb && tar xzf /snap/node1-lmdb.tar.gz -C /data && rm -f /data/lmdb/lock.mdb'
    docker run --rm -v zephyr-node2-data:/data -v "$SNAPSHOT_DIR:/snap:ro" alpine \
        sh -c 'rm -rf /data/lmdb && tar xzf /snap/node2-lmdb.tar.gz -C /data && rm -f /data/lmdb/lock.mdb'

    # 4. Start nodes
    echo "Starting nodes..."
    dc start zephyr-node1 zephyr-node2

    # 5. Wait for daemons
    wait_for_rpc "$RPC_PORT1" "node1" 30
    wait_for_sync "$RPC_PORT1" "node1" 30

    # 6. Open base wallets
    echo "Opening base wallets..."
    for name_port in "gov:$GOV_WALLET_RPC_PORT" "miner:$MINER_WALLET_RPC_PORT" "test:$TEST_WALLET_RPC_PORT"; do
        local name="${name_port%%:*}"
        local port="${name_port##*:}"
        rpc_call "$port" "open_wallet" "{\"filename\":\"$name\",\"password\":\"\"}" > /dev/null 2>&1 || \
            echo "  WARNING: Failed to open $name wallet"
    done

    # 7. Hard rescan
    echo "Hard-rescanning base wallets..."
    for wname_port in "gov:$GOV_WALLET_RPC_PORT" "miner:$MINER_WALLET_RPC_PORT" "test:$TEST_WALLET_RPC_PORT"; do
        local wname="${wname_port%%:*}"
        local wport="${wname_port##*:}"
        echo "  Rescanning $wname wallet..."
        rpc_call "$wport" "rescan_blockchain" '{"hard":true}' > /dev/null 2>&1 || echo "  WARNING: Failed to rescan $wname"
    done
    sleep 15

    # 8. Close base wallets (flush to disk)
    echo "Closing base wallets (flushing to disk)..."
    for port in "$GOV_WALLET_RPC_PORT" "$MINER_WALLET_RPC_PORT" "$TEST_WALLET_RPC_PORT"; do
        rpc_call "$port" "close_wallet" > /dev/null 2>&1 || true
    done
    sleep 1

    echo ""
    local final_height
    final_height=$(get_height "$RPC_PORT1")
    echo "=== Hard reset complete (height: $final_height) ==="
}

docker_delete() {
    echo "=== Deleting devnet (Docker) ==="
    dc down -v --remove-orphans
    echo "=== Deleted ==="
}

docker_status() {
    echo "=== Devnet Status (Docker) ==="
    echo ""

    echo "--- Containers ---"
    dc ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "  (none running)"

    echo ""
    echo "--- Chain ---"
    local h1 h2
    h1=$(get_height "$RPC_PORT1" 2>/dev/null || echo "0")
    h2=$(get_height "$RPC_PORT2" 2>/dev/null || echo "0")
    echo "  node1: height=$h1"
    echo "  node2: height=$h2"

    echo ""
    echo "--- Oracle ---"
    local oracle_status
    oracle_status=$(curl -s --max-time 2 "http://127.0.0.1:$ORACLE_PORT/status" 2>/dev/null || true)
    if [[ -n "$oracle_status" ]]; then
        echo "$oracle_status" | python3 -c "
import sys, json
r = json.load(sys.stdin)
spot = r['spot']
print(f'  spot: \${spot/1e12:.2f} ({spot} atomic)')
" 2>/dev/null
    else
        echo "  unreachable"
    fi

    echo ""
}

# ─── Dispatch ────────────────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
Usage: devnet.sh <command> [--docker]

Commands:
  start    Start the devnet stack (creates wallets, no bootstrap)
  init     Full bootstrap (mine + mint + checkpoint). Self-contained.
             --snapshot-dir DIR  Save LMDB snapshots after init (Docker)
  stop     Stop all processes
  reset    Reset to checkpoint, then stop
             --checkpoint HEIGHT Pop to this height (Docker)
             --hard              Restore from LMDB snapshots (Docker)
             --snapshot-dir DIR  Snapshot directory for hard reset (Docker)
  delete   Delete all data
  status   Show devnet health

Environment:
  DEVNET_DOCKER=1   Use Docker mode (default: native/Overmind)
  DC_CMD            Full Docker Compose command prefix (Docker mode)
  DC_ARGS           Override Docker Compose file chain (Docker mode, legacy)
  ORACLE_PRICE      Oracle price (default: 1.50)
  DEVNET_MODE       Setup mode: custom|mirror (default: custom)
EOF
    exit 1
}

case "$COMMAND" in
    start)
        if [[ "$DOCKER_MODE" -eq 1 ]]; then docker_start; else native_start; fi ;;
    init)
        if [[ "$DOCKER_MODE" -eq 1 ]]; then docker_init "$@"; else native_init; fi ;;
    stop)
        if [[ "$DOCKER_MODE" -eq 1 ]]; then docker_stop; else native_stop; fi ;;
    reset)
        if [[ "$DOCKER_MODE" -eq 1 ]]; then docker_reset "$@"; else native_reset "$@"; fi ;;
    delete)
        if [[ "$DOCKER_MODE" -eq 1 ]]; then docker_delete; else native_delete; fi ;;
    status)
        if [[ "$DOCKER_MODE" -eq 1 ]]; then docker_status; else native_status; fi ;;
    *)
        usage ;;
esac
