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
    local dc_args="${DC_ARGS:--f $REPO_ROOT/docker/compose.yml}"
    docker compose $dc_args "$@"
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

native_start() {
    echo "=== Starting devnet (native) ==="
    echo ""

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

    dc up -d
    echo ""

    echo "--- Creating wallets (wallets-only) ---"
    WALLETS_ONLY=true dc --profile init run --rm devnet-init

    echo ""
    echo "=== Devnet running (Docker) ==="
}

docker_init() {
    echo "=== Devnet Init (Docker) — full bootstrap ==="
    echo ""

    # Start services if not running
    if ! dc ps --status running -q zephyr-node1 2>/dev/null | grep -q .; then
        dc up -d
        echo ""
    fi

    genesis_guard

    echo "--- Running full devnet init ---"
    dc --profile init run --rm devnet-init

    echo ""
    echo "=== Devnet init complete (Docker) ==="
}

docker_stop() {
    echo "=== Stopping devnet (Docker) ==="
    dc down
    echo "=== Stopped ==="
}

docker_reset() {
    echo "=== Resetting devnet (Docker) ==="
    echo ""

    local current_height checkpoint_height blocks_to_pop

    current_height=$(get_height "$RPC_PORT1" 2>/dev/null || echo "0")
    if [ "$current_height" -eq 0 ]; then
        echo "Error: Node not reachable"
        exit 1
    fi

    # Read checkpoint from Docker volume via container
    checkpoint_height=$(dc exec -T devnet-init cat /checkpoint/height 2>/dev/null || echo "")
    if [ -z "$checkpoint_height" ]; then
        echo "Error: No checkpoint found"
        exit 1
    fi

    echo "Current height:    $current_height"
    echo "Checkpoint height: $checkpoint_height"

    if [ "$current_height" -le "$checkpoint_height" ]; then
        echo "Nothing to reset (current <= checkpoint)."
        return
    fi

    blocks_to_pop=$((current_height - checkpoint_height))
    echo "Blocks to pop:     $blocks_to_pop"
    echo ""

    # Stop mining
    echo "Stopping mining..."
    rpc_other "$RPC_PORT1" "stop_mining" > /dev/null 2>&1 || true
    sleep 1

    # Pop blocks on both nodes
    echo "Popping $blocks_to_pop blocks..."
    rpc_other "$RPC_PORT1" "pop_blocks" "{\"nblocks\":$blocks_to_pop}" > /dev/null 2>&1
    rpc_other "$RPC_PORT2" "pop_blocks" "{\"nblocks\":$blocks_to_pop}" > /dev/null 2>&1 || true
    sleep 2

    # Rescan wallets
    echo "Rescanning wallets..."
    _rescan_all_wallets

    echo ""
    local final_height
    final_height=$(get_height "$RPC_PORT1")
    echo "=== Reset complete (height: $final_height) ==="
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
  stop     Stop all processes
  reset    Reset to checkpoint, then stop
  delete   Delete all data
  status   Show devnet health

Environment:
  DEVNET_DOCKER=1   Use Docker mode (default: native/Overmind)
  DC_ARGS           Override Docker Compose file chain
  ORACLE_PRICE      Oracle price (default: 1.50)
  DEVNET_MODE       Setup mode: custom|mirror (default: custom)
EOF
    exit 1
}

case "$COMMAND" in
    start)
        if [[ "$DOCKER_MODE" -eq 1 ]]; then docker_start; else native_start; fi ;;
    init)
        if [[ "$DOCKER_MODE" -eq 1 ]]; then docker_init; else native_init; fi ;;
    stop)
        if [[ "$DOCKER_MODE" -eq 1 ]]; then docker_stop; else native_stop; fi ;;
    reset)
        if [[ "$DOCKER_MODE" -eq 1 ]]; then docker_reset; else native_reset "$@"; fi ;;
    delete)
        if [[ "$DOCKER_MODE" -eq 1 ]]; then docker_delete; else native_delete; fi ;;
    status)
        if [[ "$DOCKER_MODE" -eq 1 ]]; then docker_status; else native_status; fi ;;
    *)
        usage ;;
esac
