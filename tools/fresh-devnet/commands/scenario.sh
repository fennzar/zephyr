#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

# Scenario presets (price-only, no orderbook/spread)
declare -A SCENARIO_PRICES
SCENARIO_PRICES["normal"]="15.00"
SCENARIO_PRICES["defensive"]="0.80"
SCENARIO_PRICES["crisis"]="0.40"
SCENARIO_PRICES["recovery"]="2.00"
SCENARIO_PRICES["high-rr"]="25.00"
SCENARIO_PRICES["volatility"]="5.00"
SCENARIO_PRICES["high-spread"]="15.00"
SCENARIO_PRICES["depeg"]="15.00"

declare -A SCENARIO_DESCS
SCENARIO_DESCS["normal"]="Normal mode (RR ~700%) - all operations available"
SCENARIO_DESCS["defensive"]="Defensive mode (RR ~280%) - ZSD/ZRS mint blocked"
SCENARIO_DESCS["crisis"]="Crisis mode (RR ~90%) - ZSD haircut, ZRS blocked"
SCENARIO_DESCS["recovery"]="Recovery to normal (RR ~500%) - all ops resume"
SCENARIO_DESCS["high-rr"]="High RR mode (RR >800%) - ZRS mint blocked, redeem OK"
SCENARIO_DESCS["volatility"]="Edge of normal/defensive (RR ~400%)"
SCENARIO_DESCS["high-spread"]="Normal mode, wide spread - testing arb detection"
SCENARIO_DESCS["depeg"]="Normal price, stablecoin depeg simulation"

preset="${1:-}"

if [[ -z "$preset" || "$preset" == "-h" || "$preset" == "--help" ]]; then
    echo "Usage: run.sh scenario <preset>"
    echo ""
    echo "Available presets:"
    echo ""
    printf "  %-12s %-8s %s\n" "PRESET" "PRICE" "DESCRIPTION"
    printf "  %-12s %-8s %s\n" "------" "-----" "-----------"
    for name in normal defensive crisis recovery high-rr volatility high-spread depeg; do
        printf "  %-12s \$%-7s %s\n" "$name" "${SCENARIO_PRICES[$name]}" "${SCENARIO_DESCS[$name]}"
    done
    echo ""
    echo "Examples:"
    echo "  run.sh scenario normal      # Standard testing"
    echo "  run.sh scenario defensive   # Test defensive mode triggers"
    echo "  run.sh scenario crisis      # Test crisis mode behavior"
    exit 0
fi

if [[ -z "${SCENARIO_PRICES[$preset]:-}" ]]; then
    echo "Error: Unknown preset '$preset'"
    echo ""
    echo "Available presets: normal, defensive, crisis, recovery, high-rr, volatility, high-spread, depeg"
    exit 1
fi

price="${SCENARIO_PRICES[$preset]}"
desc="${SCENARIO_DESCS[$preset]}"

echo "=== Setting Scenario: $preset ==="
echo ""
echo "  Price:       \$$price"
echo "  Description: $desc"
echo ""

"$(dirname "$0")/set-price.sh" "$price"
