#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

echo "=== Stopping devnet ==="

if [[ -S "$OVERMIND_SOCK" ]]; then
    echo "Stopping overmind..."
    overmind quit -s "$OVERMIND_SOCK" 2>/dev/null || true
    # Wait for socket to disappear (up to 10s)
    for i in $(seq 1 100); do
        [[ -S "$OVERMIND_SOCK" ]] || break
        sleep 0.1
    done
    # Clean up stale socket
    rm -f "$OVERMIND_SOCK"
fi

# Fallback: kill any lingering processes
pkill -f "zephyrd.*--devnet.*$DATA_DIR" 2>/dev/null || true
pkill -f "zephyr-wallet-rpc.*--devnet.*$DATA_DIR" 2>/dev/null || true
pkill -f "node.*fake-oracle/server.js" 2>/dev/null || true

echo "=== All stopped ==="
