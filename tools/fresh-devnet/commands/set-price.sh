#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

ZEPHYR_CLI="$REPO_ROOT/tools/zephyr-cli/cli"

dollars="${1:-}"

if [[ -z "$dollars" ]]; then
    echo "Usage: run.sh set-price <dollars>"
    echo "Example: run.sh set-price 1.50"
    exit 1
fi

# Validate price is a positive number
if ! [[ "$dollars" =~ ^[0-9]+\.?[0-9]*$ ]]; then
    echo "Error: Invalid price '$dollars' (must be a positive number)"
    exit 1
fi
if [[ "$(echo "$dollars <= 0" | bc -l)" -eq 1 ]]; then
    echo "Error: Price must be greater than 0"
    exit 1
fi

echo "Setting oracle spot price to \$$dollars..."

if [[ -x "$ZEPHYR_CLI" ]]; then
    "$ZEPHYR_CLI" price "$dollars"
else
    atomic=$(python3 -c "print(int(float('$dollars') * 1e12))")
    response=$(curl -s -X POST "http://127.0.0.1:$ORACLE_PORT/set-price" \
        -H 'Content-Type: application/json' \
        -d "{\"spot\": $atomic}")
    if echo "$response" | grep -q '"status"'; then
        echo "Price updated."
    else
        echo "WARNING: Unexpected response: $response"
    fi
fi

# Estimate RR mode
echo ""
echo -e "Estimated RR mode: $(estimate_rr_mode "$dollars")"
echo ""
echo "Note: Actual RR depends on reserve state. New blocks will use the updated price."
