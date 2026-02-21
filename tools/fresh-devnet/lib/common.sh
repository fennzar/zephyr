#!/bin/bash
# Shared constants, RPC helpers, and utility functions for fresh-devnet scripts.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
BUILD_DIR="$REPO_ROOT/build/devnet"
DATA_DIR="/tmp/zephyr-devnet"
NODE1_DATA="$DATA_DIR/node1"
NODE2_DATA="$DATA_DIR/node2"
WALLET_DIR="$DATA_DIR/wallets"

# Ports
P2P_PORT1=47766
RPC_PORT1=47767
ZMQ_PORT1=47768
P2P_PORT2=47866
RPC_PORT2=47867
ZMQ_PORT2=47868
ORACLE_PORT=5555
MINER_WALLET_RPC_PORT=48767
TEST_WALLET_RPC_PORT=48768
GOV_WALLET_RPC_PORT=48769

# Oracle default price: $1.50
DEFAULT_SPOT=1500000000000

# Overmind
OVERMIND_SOCK="$DATA_DIR/overmind.sock"

# Snapshots (persistent across reboots, unlike /tmp)
SNAPSHOT_DIR="$HOME/.zephyr-devnet/snapshots"

# Checkpoint files (saved after state setup for fast reset)
CHECKPOINT_FILE="$DATA_DIR/checkpoint_height"
CHECKPOINT_INFO_FILE="$DATA_DIR/checkpoint_info.json"

# Governance wallet keys (deterministic, for devnet only)
GOV_ADDRESS="ZPHSjqHRP2cPUoxHrVXe8K6rjdDdA9JF8WL549DrkDVtiYYbkfkJSvc4bQ6iXVb11Z3hcGETaNPgiMG5wu3fCPjviLk4Nu69oJy"
GOV_SPEND_KEY="dcf91a5b3e9913e0b78aa9460636f61ac9df37bbb003d795a555553214c83e09"
GOV_VIEW_KEY="0ad41f7f73ee411387fbcf722364db676022f08c54fa4bb4708b6eec8c6b1a00"

# Disable RandomX large pages to avoid bad_alloc on systems without huge pages
export MONERO_RANDOMX_UMASK=1

# ─── RPC helpers ──────────────────────────────────────────────────────────────

rpc_call() {
    local port="$1" method="$2" params="${3:-{}}"
    curl -s --max-time 5 http://127.0.0.1:"$port"/json_rpc \
        -H 'Content-Type: application/json' \
        -d "{\"jsonrpc\":\"2.0\",\"id\":\"0\",\"method\":\"$method\",\"params\":$params}" 2>/dev/null
}

rpc_other() {
    local port="$1" endpoint="$2" data="${3:-{}}"
    curl -s --max-time 5 http://127.0.0.1:"$port"/"$endpoint" \
        -H 'Content-Type: application/json' \
        -d "$data" 2>/dev/null
}

# ─── Wait helpers ─────────────────────────────────────────────────────────────

wait_for_rpc() {
    local port="$1" name="$2" max_wait="${3:-30}"
    echo -n "Waiting for $name RPC (port $port)..."
    for i in $(seq 1 "$max_wait"); do
        if rpc_call "$port" "get_info" 2>/dev/null | grep -q '"status"'; then
            echo " ready"
            return 0
        fi
        sleep 1
        echo -n "."
    done
    echo " TIMEOUT"
    return 1
}

wait_for_wallet_rpc() {
    local port="$1" name="$2" max_wait="${3:-30}"
    echo -n "Waiting for $name wallet-rpc (port $port)..."
    for i in $(seq 1 "$max_wait"); do
        if rpc_call "$port" "get_version" 2>/dev/null | grep -q '"version"'; then
            echo " ready"
            return 0
        fi
        sleep 1
        echo -n "."
    done
    echo " TIMEOUT"
    return 1
}

get_height() {
    local port="${1:-$RPC_PORT1}"
    rpc_call "$port" "get_info" | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['height'])" 2>/dev/null || echo "0"
}

wait_for_height() {
    local target="$1" port="${2:-$RPC_PORT1}"
    local height
    echo -n "Waiting for height >= $target..."
    while true; do
        height=$(get_height "$port")
        if [[ "$height" -ge "$target" ]]; then
            echo " height=$height"
            return 0
        fi
        sleep 1
        echo -n "."
    done
}

wait_for_sync() {
    local port="$1" name="$2" max_wait="${3:-30}"
    echo -n "Waiting for $name to synchronize..."
    for i in $(seq 1 "$max_wait"); do
        local synced
        synced=$(rpc_call "$port" "get_info" | python3 -c "
import sys,json
try:
    r = json.load(sys.stdin)['result']
    print('1' if r.get('synchronized', False) else '0')
except:
    print('0')
" 2>/dev/null)
        if [[ "$synced" == "1" ]]; then
            echo " synced"
            return 0
        fi
        sleep 1
        echo -n "."
    done
    echo " TIMEOUT (proceeding anyway)"
    return 0
}

# ─── Wallet helpers ───────────────────────────────────────────────────────────

wallet_refresh() {
    local port="$1"
    rpc_call "$port" "refresh" > /dev/null 2>&1
}

wallet_get_balance() {
    local port="$1"
    wallet_refresh "$port"
    rpc_call "$port" "get_balance" '{"account_index":0,"all_assets":true}'
}

get_reserve_info() {
    rpc_call "$RPC_PORT1" "get_reserve_info"
}

estimate_rr_mode() {
    local usd_price="$1"
    python3 -c "
p = float('$usd_price')
GREEN = '\033[0;32m'
YELLOW = '\033[1;33m'
RED = '\033[0;31m'
NC = '\033[0m'
if p >= 1.50:
    print(f'{GREEN}NORMAL{NC} - RR likely >400%')
elif p >= 0.60:
    print(f'{YELLOW}DEFENSIVE{NC} - RR likely 200-400%')
else:
    print(f'{RED}CRISIS{NC} - RR likely <200%')
"
}

get_miner_address() {
    rpc_call "$MINER_WALLET_RPC_PORT" "get_address" '{"account_index":0}' | \
        python3 -c "import sys,json; print(json.load(sys.stdin)['result']['address'])" 2>/dev/null
}

_rescan_all_wallets() {
    for wname_port in "gov:$GOV_WALLET_RPC_PORT" "miner:$MINER_WALLET_RPC_PORT" "test:$TEST_WALLET_RPC_PORT"; do
        local wname="${wname_port%%:*}"
        local wport="${wname_port##*:}"
        echo "  Rescanning $wname wallet..."
        rpc_call "$wport" "rescan_blockchain" '{"hard":false}' > /dev/null 2>&1 || echo "  WARNING: Failed to rescan $wname"
        rpc_call "$wport" "refresh" > /dev/null 2>&1 || true
    done
}

_restart_mining() {
    local miner_addr
    miner_addr=$(get_miner_address)
    if [[ -n "$miner_addr" && "$miner_addr" != "null" ]]; then
        rpc_other "$RPC_PORT1" "start_mining" "{
            \"do_background_mining\": false,
            \"ignore_battery\": true,
            \"miner_address\": \"$miner_addr\",
            \"threads_count\": 2
        }" > /dev/null 2>&1
        echo "Mining restarted"
    else
        echo "WARNING: Could not get miner address, mining not restarted"
    fi
}

# ─── Overmind helpers ─────────────────────────────────────────────────────────

overmind_running() {
    [[ -S "$OVERMIND_SOCK" ]] && overmind ps -s "$OVERMIND_SOCK" &>/dev/null
}

_generate_procfile() {
    cat > "$DATA_DIR/Procfile" <<EOF
oracle: ORACLE_PORT=$ORACLE_PORT node $REPO_ROOT/tools/fake-oracle/server.js
node1: MONERO_RANDOMX_UMASK=1 $BUILD_DIR/bin/zephyrd --devnet --data-dir $NODE1_DATA --fixed-difficulty 1 --p2p-bind-port $P2P_PORT1 --rpc-bind-port $RPC_PORT1 --zmq-rpc-bind-port $ZMQ_PORT1 --rpc-bind-ip 0.0.0.0 --confirm-external-bind --add-exclusive-node 127.0.0.1:$P2P_PORT2 --non-interactive --log-level 1
node2: MONERO_RANDOMX_UMASK=1 $BUILD_DIR/bin/zephyrd --devnet --data-dir $NODE2_DATA --fixed-difficulty 1 --p2p-bind-port $P2P_PORT2 --rpc-bind-port $RPC_PORT2 --zmq-rpc-bind-port $ZMQ_PORT2 --add-exclusive-node 127.0.0.1:$P2P_PORT1 --non-interactive --log-level 1
gov-wallet: $BUILD_DIR/bin/zephyr-wallet-rpc --devnet --rpc-bind-port $GOV_WALLET_RPC_PORT --disable-rpc-login --wallet-dir $WALLET_DIR --daemon-port $RPC_PORT1 --trusted-daemon --shared-ringdb-dir $DATA_DIR/ringdb --log-level 1
miner-wallet: $BUILD_DIR/bin/zephyr-wallet-rpc --devnet --rpc-bind-port $MINER_WALLET_RPC_PORT --disable-rpc-login --wallet-dir $WALLET_DIR --daemon-port $RPC_PORT1 --trusted-daemon --shared-ringdb-dir $DATA_DIR/ringdb --log-level 1
test-wallet: $BUILD_DIR/bin/zephyr-wallet-rpc --devnet --rpc-bind-port $TEST_WALLET_RPC_PORT --disable-rpc-login --wallet-dir $WALLET_DIR --daemon-port $RPC_PORT1 --trusted-daemon --shared-ringdb-dir $DATA_DIR/ringdb --log-level 1
EOF
}
