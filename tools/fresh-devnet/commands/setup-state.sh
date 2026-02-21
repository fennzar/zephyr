#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

ZEPHYR_CLI="$REPO_ROOT/tools/zephyr-cli/cli"

if [[ ! -x "$ZEPHYR_CLI" ]]; then
    echo "Error: zephyr-cli not found at $ZEPHYR_CLI"
    exit 1
fi

do_wait() {
    local blocks=${1:-10}
    local current_h
    current_h=$("$ZEPHYR_CLI" height)
    echo "  Waiting $blocks blocks (target: $((current_h + blocks)))..."
    "$ZEPHYR_CLI" wait $((current_h + blocks))
}

echo "=== Setting up initial network state ==="
echo ""
echo "Ring size is 2 for DEVNET (1 decoy). Sequential minting with waits."
echo "Each transaction creates outputs that serve as ring members for future txs."
echo "More transactions = more ring diversity = reliable transfers post-reset."
echo ""

# Refresh and show starting balance
"$ZEPHYR_CLI" refresh gov 2>/dev/null || true
sleep 1
echo "Gov wallet balance:"
"$ZEPHYR_CLI" balances gov

echo ""
echo "--- Phase 1: Mint ZRS (3 rounds x 300,000 ZPH each = 900k ZPH -> ZRS) ---"
for i in 1 2 3; do
    echo "  ZRS mint $i/3:"
    "$ZEPHYR_CLI" convert gov 300000 ZPH ZRS
    do_wait 12
done

# Extra wait before Phase 2 to ensure all ZPH change outputs are unlocked
echo ""
echo "--- Waiting for ZPH outputs to fully unlock before ZSD minting ---"
do_wait 20

echo ""
echo "--- Phase 2: Mint ZSD (3 rounds x 50,000 ZPH each = 150k ZPH -> ~225k ZSD) ---"
for i in 1 2 3; do
    echo "  ZSD mint $i/3:"
    "$ZEPHYR_CLI" convert gov 50000 ZPH ZSD
    do_wait 12
done

# Extra wait before Phase 3 to ensure all ZSD outputs are unlocked
echo ""
echo "--- Waiting for ZSD outputs to fully unlock before ZYS minting ---"
do_wait 20

echo ""
echo "--- Phase 3: Mint ZYS (3 rounds x 25,000 ZSD each = 75k ZSD -> ZYS) ---"
for i in 1 2 3; do
    echo "  ZYS mint $i/3:"
    "$ZEPHYR_CLI" convert gov 25000 ZSD ZYS
    do_wait 12
done

# Wait before fund distribution
echo ""
echo "--- Waiting for outputs to unlock before fund distribution ---"
do_wait 20

echo ""
echo "--- Phase 4: Fund test and miner wallets ---"
echo "  Multiple sends create ring-eligible outputs for all wallets."
for i in 1 2 3; do
    echo "  ZPH send $i/3: 10000 -> test"
    "$ZEPHYR_CLI" send gov test 10000
    do_wait 12
done
echo "  ZSD send: 5000 -> test"
"$ZEPHYR_CLI" send gov test 5000 ZSD
do_wait 12
echo "  ZPH send: 5000 -> miner"
"$ZEPHYR_CLI" send gov miner 5000
do_wait 12

echo ""
echo "--- Phase 5: Create additional outputs (ring diversity) ---"
echo "  Self-sends and small conversions to populate the output set."
echo "  This ensures transfers work reliably after checkpoint reset."
for i in 1 2 3 4; do
    echo "  ZPH self-send $i/4: 1000"
    "$ZEPHYR_CLI" send gov gov 1000
    do_wait 10
done
for i in 1 2; do
    echo "  ZSD self-send $i/2: 500"
    "$ZEPHYR_CLI" send gov gov 500 ZSD
    do_wait 10
done

# Final wait for all outputs to unlock
echo ""
echo "--- Final wait for all outputs to unlock ---"
do_wait 20

echo ""
echo "=== State setup complete ==="
echo ""
"$ZEPHYR_CLI" balances
