#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
    cat <<'EOF'
Usage: run.sh <command> [args]

Commands:
  build              Build devnet binaries in build/devnet
  start [new|<name>] Start devnet (shows snapshots if available, or 'new' / snapshot name)
  stop               Kill all devnet processes
  status             Show running processes, chain height, balances, reserve info
  set-price N        Set oracle spot price to $N (e.g. set-price 1.50)
  setup-state        (Re)run initial state setup from governance wallet
  checkpoint [--show]  Save current height as reset point (auto-saved after start)
  reset [--status|--force|--recover]  Pop blocks to checkpoint, rescan wallets (~30s)
  scenario <name>    Apply a price preset (normal, defensive, crisis, recovery, high-rr, volatility)
  connect [service]  Attach to a process output (no args lists available processes)
  save [name]        Save running devnet state to a named snapshot (default: "default")
  restore [name]     Restore a saved snapshot and start devnet from it
EOF
    exit 1
}

case "${1:-}" in
    build)       "$SCRIPT_DIR/commands/build.sh" ;;
    start)       "$SCRIPT_DIR/commands/start.sh" "${2:-}" ;;
    stop)        "$SCRIPT_DIR/commands/stop.sh" ;;
    status)      "$SCRIPT_DIR/commands/status.sh" ;;
    set-price)   "$SCRIPT_DIR/commands/set-price.sh" "${2:-}" ;;
    setup-state) "$SCRIPT_DIR/commands/setup-state.sh" ;;
    checkpoint)  "$SCRIPT_DIR/commands/checkpoint.sh" "${2:-}" ;;
    reset)       shift; "$SCRIPT_DIR/commands/reset.sh" "$@" ;;
    scenario)    "$SCRIPT_DIR/commands/scenario.sh" "${2:-}" ;;
    connect)     "$SCRIPT_DIR/commands/connect.sh" "${2:-}" ;;
    save)        "$SCRIPT_DIR/commands/save.sh" "${2:-default}" ;;
    restore)     "$SCRIPT_DIR/commands/restore.sh" "${2:-}" ;;
    *)           usage ;;
esac
