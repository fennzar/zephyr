#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

service="${1:-}"

if ! overmind_running; then
    echo "Error: Devnet is not running (no overmind socket at $OVERMIND_SOCK)"
    exit 1
fi

if [[ -z "$service" ]]; then
    echo "Available processes:"
    echo ""
    overmind ps -s "$OVERMIND_SOCK" 2>/dev/null || echo "  (unable to list)"
    echo ""
    echo "Usage: run.sh connect <service>"
    echo "Example: run.sh connect node1"
    echo ""
    echo "Press Ctrl+C to detach once connected."
    exit 0
fi

overmind connect -s "$OVERMIND_SOCK" "$service"
