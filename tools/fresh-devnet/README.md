# Zephyr DEVNET Test Harness

A fully automated local devnet for testing Zephyr Protocol features. Starts a fake oracle, two peered nodes, three wallet-rpc instances, mines blocks, and sets up realistic network state with all asset types.

## Prerequisites

- **overmind** (process manager) + **tmux** (required by overmind)
- Both should already be installed; verify with `overmind -v` and `tmux -V`

## Quick Start

```bash
# Build (first time only)
./tools/fresh-devnet/run.sh build

# Start devnet (oracle + nodes + wallets + mining + initial state setup)
./tools/fresh-devnet/run.sh start

# Check status
./tools/fresh-devnet/run.sh status

# Change oracle price
./tools/fresh-devnet/run.sh set-price 2.50

# Apply a scenario preset (sets price for a target RR mode)
./tools/fresh-devnet/run.sh scenario defensive

# Reset to post-init state without full restart (~30s vs ~5min)
./tools/fresh-devnet/run.sh reset

# Save/show checkpoint
./tools/fresh-devnet/run.sh checkpoint --show

# Attach to a process output (Ctrl+C to detach)
./tools/fresh-devnet/run.sh connect node1

# Stop everything
./tools/fresh-devnet/run.sh stop
```

## What `start` Does

1. Stops any running devnet (via overmind)
2. Cleans `/tmp/zephyr-devnet/` (fresh chain each time)
3. Generates a Procfile and starts all 6 processes via overmind:
   - Fake oracle, two nodes, three wallet-rpc instances
4. Waits for all RPC endpoints to be ready
5. Restores governance wallet from known keys
6. Creates miner and test wallets
7. Starts mining on node1 (2 threads, difficulty=1)
8. Waits 70 blocks for governance funds to unlock
9. Mints ZRS, ZSD, ZYS sequentially to bootstrap network state
10. **Auto-saves checkpoint** for fast reset later
11. Prints status summary

Total startup time: ~5-6 minutes (most spent waiting for blocks).

## File Structure

```
tools/fresh-devnet/
  run.sh              # Thin dispatcher (~35 lines)
  lib/
    common.sh         # Shared constants, RPC helpers, utility functions
  commands/
    build.sh          # cmake build
    start.sh          # overmind start + wallet setup + mining + state + checkpoint
    stop.sh           # overmind quit + fallback cleanup
    status.sh         # processes + chain + wallets
    setup-state.sh    # mint ZRS/ZSD/ZYS
    checkpoint.sh     # save/show checkpoint
    reset.sh          # pop blocks + rescan + restart mining
    scenario.sh       # price presets
    set-price.sh      # oracle price with validation
    connect.sh        # attach to process output (wraps overmind connect)
  README.md
```

## Ports

| Service | Port |
|---------|------|
| Fake Oracle | 5555 |
| Node1 P2P | 47766 |
| Node1 RPC | 47767 |
| Node1 ZMQ | 47768 |
| Node2 P2P | 47866 |
| Node2 RPC | 47867 |
| Gov Wallet RPC | 48769 |
| Miner Wallet RPC | 48767 |
| Test Wallet RPC | 48768 |

## Network State After Bootstrap

| Asset | Amount | Description |
|-------|--------|-------------|
| ZPH | ~872,000 | Remaining in gov wallet |
| ZRS | ~1,765,000 | Reserve tokens |
| ZSD | ~150,000 | Stablecoins |
| ZYS | ~75,000 | Yield tokens |

- **Reserve ratio: ~7.0** (healthy — well above 4.0 minimum)
- All asset types have outputs for ring signatures
- Mining continues, adding ~11 ZPH per block to miner wallet

## Architecture

### Process Management

All 6 long-running processes are managed by **overmind** (a Procfile-based process manager built on tmux). Benefits over the previous PID-based approach:

- No orphaned processes or stale PID files
- `run.sh connect <service>` attaches to live process output
- `run.sh stop` cleanly shuts down everything via `overmind quit`
- Process restarts and health monitoring handled by overmind

The Procfile is generated at runtime in `$DATA_DIR/Procfile` with resolved paths.

### Ring Size

DEVNET uses **ring size 2** (1 decoy) instead of mainnet's 16. This allows transactions to work immediately without needing 15+ pre-existing outputs per asset type. The ring size is enforced at both:
- Consensus level (`blockchain.cpp`)
- Wallet level (`wallet2.cpp`)

### Initial State Setup

After 70 blocks (governance funds unlock), sequential minting:

1. **3 ZRS mints** (300,000 ZPH each = 900k ZPH -> ZRS)
2. **3 ZSD mints** (50,000 ZPH each = 150k ZPH -> ~225k ZSD)
3. **3 ZYS mints** (25,000 ZSD each = 75k ZSD -> ZYS)

Each mint waits 10 blocks for change outputs to unlock before the next.

### Governance Wallet

The governance wallet receives 1,921,650 ZPH (UNAUDITABLE_ZEPH_AMOUNT) at block 1. Uses known keys (hardcoded for deterministic devnet setup):

- **Address:** `ZPHSjqHRP2cPUoxHrVXe8K6rjdDdA9JF8WL549DrkDVtiYYbkfkJSvc4bQ6iXVb11Z3hcGETaNPgiMG5wu3fCPjviLk4Nu69oJy`
- **Spend key:** `dcf91a5b3e9913e0b78aa9460636f61ac9df37bbb003d795a555553214c83e09`
- **View key:** `0ad41f7f73ee411387fbcf722364db676022f08c54fa4bb4708b6eec8c6b1a00`

**WARNING:** These are publicly known test keys. Never use on mainnet/stagenet.

## Reset Workflow

After `start`, the devnet saves a checkpoint automatically. Use `reset` to quickly return to that post-init state without a full restart.

### When to use what

| Situation | Command | Time |
|-----------|---------|------|
| First run or corrupted state | `run.sh start` | ~5 min |
| Revert price/mint experiments | `run.sh reset` | ~30 sec |
| Wallet out of sync after reset failure | `run.sh reset --recover` | ~10 sec |
| Check how far chain has advanced | `run.sh reset --status` | instant |

### How reset works

1. Stops mining
2. Pops blocks on both nodes back to the checkpoint height
3. Rescans all wallets (gov, miner, test)
4. Restarts mining with the miner wallet address
5. Chain continues from the checkpoint state

### Manual checkpoints

You can save a new checkpoint at any time:

```bash
# Save current state as checkpoint
./tools/fresh-devnet/run.sh checkpoint

# View saved checkpoint info
./tools/fresh-devnet/run.sh checkpoint --show
```

## Scenario Presets

Quick presets set the oracle price to simulate different reserve ratio modes:

```bash
./tools/fresh-devnet/run.sh scenario <preset>
```

| Preset | Price | Est. RR | Mode | Use Case |
|--------|-------|---------|------|----------|
| `normal` | $15.00 | ~700% | Normal | Standard testing, all operations available |
| `defensive` | $0.80 | ~280% | Defensive | ZSD/ZRS mint blocked |
| `crisis` | $0.40 | ~90% | Crisis | ZSD haircut, ZRS blocked |
| `recovery` | $2.00 | ~500% | Normal | Recovery from defensive state |
| `high-rr` | $25.00 | >800% | High RR | ZRS mint blocked, redeem OK |
| `volatility` | $5.00 | ~400% | Edge | Edge of normal/defensive boundary |

### RR Mode Definitions

| Mode | RR Range | Behavior |
|------|----------|----------|
| Crisis | <200% | ZSD redeems with haircut, ZRS operations blocked |
| Defensive | 200-400% | ZSD/ZRS minting blocked, redeems allowed |
| Normal | 400-800% | All operations available |
| High RR | >800% | ZRS minting blocked to prevent over-collateralization |

### Example: Testing a defensive-to-recovery cycle

```bash
# 1. Start fresh
./tools/fresh-devnet/run.sh start

# 2. Drop into defensive mode
./tools/fresh-devnet/run.sh scenario defensive
# Wait a few blocks, test that mints are blocked

# 3. Recover to normal
./tools/fresh-devnet/run.sh scenario recovery
# Wait a few blocks, verify mints work again

# 4. Reset and try a different scenario
./tools/fresh-devnet/run.sh reset
./tools/fresh-devnet/run.sh scenario crisis
```

## Price Testing (Manual)

For fine-grained price control beyond the presets:

```bash
# Healthy state (default)
./tools/fresh-devnet/run.sh set-price 1.50   # RR ~7.0

# Undercollateralized (below 4.0 threshold)
./tools/fresh-devnet/run.sh set-price 0.50   # RR ~2.3

# Overcollateralized
./tools/fresh-devnet/run.sh set-price 4.00   # RR ~18.7
```

`set-price` validates input, shows the updated oracle status, and estimates the resulting RR mode.

## RPC Examples

### Check Balance

```bash
curl -s http://127.0.0.1:48769/json_rpc -d '{
  "jsonrpc":"2.0","id":"0","method":"get_balance",
  "params":{"account_index":0,"all_assets":true}
}'
```

### Mint ZSD (ZPH -> ZSD)

```bash
curl -s http://127.0.0.1:48769/json_rpc -d '{
  "jsonrpc":"2.0","id":"0","method":"transfer",
  "params":{
    "destinations":[{"amount":1000000000000,"address":"<YOUR_ADDR>"}],
    "source_asset":"ZPH",
    "destination_asset":"ZSD"
  }
}'
```

### Asset Conversion Pairs

| Source | Destination | Operation |
|--------|-------------|-----------|
| ZPH | ZRS | Mint reserve |
| ZRS | ZPH | Redeem reserve |
| ZPH | ZSD | Mint stable |
| ZSD | ZPH | Redeem stable |
| ZSD | ZYS | Mint yield |
| ZYS | ZSD | Redeem yield |

### Query Reserve Info

```bash
curl -s http://127.0.0.1:47767/json_rpc -d '{
  "jsonrpc":"2.0","id":"0","method":"get_reserve_info"
}'
```

### Query Circulating Supply

```bash
curl -s http://127.0.0.1:47767/json_rpc -d '{
  "jsonrpc":"2.0","id":"0","method":"get_circulating_supply"
}'
```

## Wallet Operations

### Asset Types

| Asset | Symbol | Description |
|-------|--------|-------------|
| Zephyr | ZPH | Base currency, mined by miners |
| Zephyr Reserve Share | ZRS | Reserve token, backed by ZPH in reserve |
| Zephyr Stable Dollar | ZSD | Stablecoin, pegged to $1 USD |
| Zephyr Yield Staking | ZYS | Yield token, earns fees from conversions |

### Conversion Requirements

| Conversion | Direction | RR Requirement |
|------------|-----------|---------------|
| ZPH -> ZRS | Mint reserve | RR < 800% |
| ZRS -> ZPH | Redeem reserve | RR > 200% |
| ZPH -> ZSD | Mint stable | RR > 400% |
| ZSD -> ZPH | Redeem stable | Always allowed (haircut if RR < 200%) |
| ZSD -> ZYS | Mint yield | RR > 400% |
| ZYS -> ZSD | Redeem yield | Always allowed |

### Conversion RPC Syntax

All conversions use the `transfer` RPC method with `source_asset` and `destination_asset`:

```bash
# Mint ZSD from ZPH (gov wallet, 1000 ZPH)
curl -s http://127.0.0.1:48769/json_rpc -d '{
  "jsonrpc":"2.0","id":"0","method":"transfer",
  "params":{
    "destinations":[{"amount":1000000000000000,"address":"<YOUR_ADDR>"}],
    "source_asset":"ZPH",
    "destination_asset":"ZSD"
  }
}'

# Redeem ZRS back to ZPH
curl -s http://127.0.0.1:48769/json_rpc -d '{
  "jsonrpc":"2.0","id":"0","method":"transfer",
  "params":{
    "destinations":[{"amount":100000000000000,"address":"<YOUR_ADDR>"}],
    "source_asset":"ZRS",
    "destination_asset":"ZPH"
  }
}'
```

Note: Amounts are in **atomic units** (1 ZPH = 10^12 atomic). The address is your own — conversions are self-transfers.

### Querying Balances (All Assets)

```bash
# Get all asset balances for gov wallet
curl -s http://127.0.0.1:48769/json_rpc -d '{
  "jsonrpc":"2.0","id":"0","method":"get_balance",
  "params":{"account_index":0,"all_assets":true}
}'
```

The response includes a `balances` array with `asset_type`, `balance`, and `unlocked_balance` for each asset.

### Verifying Conversions

After a conversion, check `get_transfers` to see the transaction:

```bash
curl -s http://127.0.0.1:48769/json_rpc -d '{
  "jsonrpc":"2.0","id":"0","method":"get_transfers",
  "params":{"out":true,"count":5}
}'
```

## Data Locations

All data in `/tmp/zephyr-devnet/`:

```
/tmp/zephyr-devnet/
├── node1/          # Node 1 blockchain data
├── node2/          # Node 2 blockchain data
├── wallets/        # Wallet files (.keys)
├── ringdb/         # Ring database (devnet-specific)
├── Procfile        # Generated process definitions (runtime)
└── overmind.sock   # Overmind control socket (runtime)
```

## Troubleshooting

### "not enough outputs to use"

This shouldn't happen after the ring size fix. If it does:
- Check that you're using the devnet binaries (built with `run.sh build`)
- Ensure `/tmp/zephyr-devnet/ringdb/` exists (fresh ring database)

### Wallet shows 0 balance

- Wait for wallet to sync: `curl ... "method":"refresh"`
- Check that the wallet-rpc is connected to the right daemon port

### Mining not producing blocks

- Check node1 is synchronized: `curl ... "method":"get_info"` -> `"synchronized": true`
- Verify miner address is valid: check node1 output via `run.sh connect node1`

### Oracle price not updating

- Price changes take effect in the next block
- Verify oracle is running: `curl http://127.0.0.1:5555/price`

### Reset failed mid-execution

If `reset` fails partway through (e.g. blocks popped but wallets not rescanned):

```bash
# Recovery mode: skips block pop, just rescans wallets and restarts mining
./tools/fresh-devnet/run.sh reset --recover
```

If recovery doesn't fix it, do a full restart:

```bash
./tools/fresh-devnet/run.sh start
```

### Process issues

```bash
# Check which processes are running
./tools/fresh-devnet/run.sh status

# Attach to a specific process to see its output
./tools/fresh-devnet/run.sh connect node1

# Force stop if overmind is unresponsive
./tools/fresh-devnet/run.sh stop
```
