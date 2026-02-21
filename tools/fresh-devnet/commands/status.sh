#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

ZEPHYR_CLI="$REPO_ROOT/tools/zephyr-cli/cli"

echo "=== DEVNET Status ==="
echo ""

# Check processes
echo "--- Processes ---"
if overmind_running; then
    echo "  overmind: RUNNING (socket: $OVERMIND_SOCK)"
    # Show individual process status
    while IFS= read -r line; do
        echo "  $line"
    done < <(overmind ps -s "$OVERMIND_SOCK" 2>/dev/null || true)
else
    echo "  overmind: NOT RUNNING"
fi

# Chain info
echo ""
echo "--- Chain ---"
if [[ -x "$ZEPHYR_CLI" ]]; then
    echo "  $("$ZEPHYR_CLI" info 2>/dev/null | head -5)" || echo "  node1: unreachable"
    # Also check node2 sync
    info2=$(rpc_call "$RPC_PORT2" "get_info" 2>/dev/null || true)
    if [[ -n "$info2" ]]; then
        echo "$info2" | python3 -c "
import sys, json
try:
    r = json.load(sys.stdin)['result']
    print(f'  node2: height={r[\"height\"]}, synced={r.get(\"synchronized\",\"?\")}')
except:
    print('  node2: unable to parse')
" 2>/dev/null
    else
        echo "  node2: unreachable"
    fi
else
    for port_name in "node1:$RPC_PORT1" "node2:$RPC_PORT2"; do
        name="${port_name%%:*}"
        port="${port_name##*:}"
        info=$(rpc_call "$port" "get_info" 2>/dev/null || true)
        if [[ -n "$info" ]]; then
            echo "$info" | python3 -c "
import sys, json
try:
    r = json.load(sys.stdin)['result']
    print(f'  $name: height={r[\"height\"]}, synced={r.get(\"synchronized\",\"?\")}, tx_pool={r.get(\"tx_pool_size\",0)}')
except:
    print('  $name: unable to parse')
" 2>/dev/null
        else
            echo "  $name: unreachable"
        fi
    done
fi

# Oracle
echo ""
echo "--- Oracle ---"
if [[ -x "$ZEPHYR_CLI" ]]; then
    "$ZEPHYR_CLI" price 2>/dev/null || echo "  unreachable"
else
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
fi

# Reserve info from node
echo ""
echo "--- Reserve Info ---"
if [[ -x "$ZEPHYR_CLI" ]]; then
    "$ZEPHYR_CLI" reserve_info 2>/dev/null || echo "  (unavailable)"
else
    pr_info=$(rpc_call $RPC_PORT1 "get_info" 2>/dev/null || true)
    if [[ -n "$pr_info" ]]; then
        echo "$pr_info" | python3 -c "
import sys, json
try:
    r = json.load(sys.stdin)['result']
    pr = r.get('pricing_record', {})
    if pr:
        spot = int(pr.get('spot', 0))
        reserve = int(pr.get('reserve', 0))
        stable = int(pr.get('stable', 0))
        rr = int(pr.get('reserve_ratio', 0))
        yp = int(pr.get('yield_price', 0))
        print(f'  spot: \${spot/1e12:.4f}')
        print(f'  reserve: {reserve/1e12:.4f}')
        print(f'  stable: {stable/1e12:.4f}')
        print(f'  reserve_ratio: {rr/1e12:.4f}')
        print(f'  yield_price: {yp/1e12:.4f}')
    else:
        print('  (no pricing record yet)')
except Exception as e:
    print(f'  (error: {e})')
" 2>/dev/null
    fi
fi

# Wallet balances
echo ""
echo "--- Wallet Balances ---"
if [[ -x "$ZEPHYR_CLI" ]]; then
    "$ZEPHYR_CLI" balances 2>/dev/null || echo "  (unable to fetch balances)"
else
    for wname_port in "gov:$GOV_WALLET_RPC_PORT" "miner:$MINER_WALLET_RPC_PORT" "test:$TEST_WALLET_RPC_PORT"; do
        wname="${wname_port%%:*}"
        wport="${wname_port##*:}"
        bal=$(wallet_get_balance "$wport" 2>/dev/null || true)
        if [[ -n "$bal" ]]; then
            echo "  $wname:"
            echo "$bal" | python3 -c "
import sys, json
try:
    r = json.load(sys.stdin).get('result', {})
    assets = r.get('balances', r.get('per_asset_balance', r.get('balance_all_assets', [])))
    for ab in assets:
        asset = ab.get('asset_type', 'ZEPH')
        bal = int(ab.get('balance', 0))
        unlocked = int(ab.get('unlocked_balance', 0))
        if bal > 0:
            print(f'    {asset}: {bal/1e12:.4f} (unlocked: {unlocked/1e12:.4f})')
    if not assets:
        print('    (no balances)')
except:
    print('    (unable to parse)')
" 2>/dev/null
        else
            echo "  $wname: unreachable"
        fi
    done
fi

echo ""
