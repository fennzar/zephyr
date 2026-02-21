# zephyr-cli

A Python CLI for interacting with the Zephyr devnet. Wraps daemon, wallet, and oracle RPC endpoints into high-level commands for wallet operations, multi-asset conversions, mining control, and price management.

## Quick Start

```bash
# One-shot command
./cli balances

# Interactive shell
./cli
zephyr> balances
zephyr> send gov miner 100
zephyr> quit
```

Requires Python 3.12+ and the `requests` library. Also depends on the internal `utils/python-rpc/` framework.

## Configuration

Configuration is loaded with this priority:

1. `-c/--config <path>` CLI flag
2. Bundled `configs/devnet.json` (default)
3. Hardcoded defaults in `config.py`

### Default Ports (devnet)

| Service | Port |
|---|---|
| Daemon RPC | 47767 |
| Oracle | 5555 |
| Gov Wallet | 48769 |
| Miner Wallet | 48767 |
| Test Wallet | 48768 |

All on `127.0.0.1`.

## Commands

### Wallet Transfers

```bash
./cli transfer <wallet> <address> <amount>          # ZPH -> ZPH
./cli stable_transfer <wallet> <address> <amount>    # ZSD -> ZSD
./cli reserve_transfer <wallet> <address> <amount>   # ZRS -> ZRS
./cli yield_transfer <wallet> <address> <amount>     # ZYS -> ZYS
```

### Asset Conversions

```bash
./cli mint_stable <wallet> <address> <amount>        # ZPH -> ZSD
./cli redeem_stable <wallet> <address> <amount>      # ZSD -> ZPH
./cli mint_reserve <wallet> <address> <amount>       # ZPH -> ZRS
./cli redeem_reserve <wallet> <address> <amount>     # ZRS -> ZPH
./cli mint_yield <wallet> <address> <amount>         # ZSD -> ZYS
./cli redeem_yield <wallet> <address> <amount>       # ZYS -> ZSD
```

### Convenience

```bash
./cli convert <wallet> <amount> <from> <to>    # Self-transfer conversion
./cli send <from_wallet> <to_wallet> <amount> [asset]  # Named wallet-to-wallet
```

Examples:
```bash
./cli convert gov 1000 zph zsd       # Mint 1000 ZSD from ZPH in gov wallet
./cli send gov miner 500 zph         # Send 500 ZPH from gov to miner
```

### Info

```bash
./cli balances [wallet]    # All wallets or single wallet
./cli address <wallet>     # Primary address
./cli refresh <wallet>     # Resync with blockchain
./cli reserve_info         # Reserve system state
./cli yield_info           # Yield system state
./cli supply_info          # Supply info
./cli price [value]        # Get/set oracle price (USD)
```

### Daemon Operations

```bash
./cli height                            # Current blockchain height
./cli wait <target_height>              # Block until height reached
./cli mine start [--wallet W] [--threads N]  # Start mining (default: miner, 2 threads)
./cli mine stop                         # Stop mining
./cli rescan [wallet|all]               # Rescan blockchain
./cli info                              # Daemon info (height, version, etc.)
./cli pop <count>                       # Pop N blocks from chain
```

## Asset System

| Asset | Symbol | Description |
|---|---|---|
| Zephyr | ZPH | Base mined currency |
| Stablecoin | ZSD | Pegged to $1 USD |
| Reserve Share | ZRS | Backed by ZPH in reserve |
| Yield Token | ZYS | Earns fees from conversions |

Conversion paths:
```
ZPH <-> ZSD   (mint_stable / redeem_stable)
ZPH <-> ZRS   (mint_reserve / redeem_reserve)
ZSD <-> ZYS   (mint_yield / redeem_yield)
```

Amounts are entered as floats (e.g. `1000`) and converted to atomic units internally (1 coin = 10^12 atomic units).

## Architecture

```
./cli
  -> ZephyrClient
       |-> Wallet RPC   (wallet-rpc instances on configured ports)
       |-> Daemon RPC   (daemon on port 47767)
       |-> Oracle HTTP   (fake-oracle on port 5555)
  -> ZephyrShell (interactive) or run_command (one-shot)
```

## Usage in fresh-devnet

The fresh-devnet scripts use zephyr-cli for all RPC operations:

```bash
"$REPO_ROOT/tools/zephyr-cli/cli" info
"$REPO_ROOT/tools/zephyr-cli/cli" price 1.50
"$REPO_ROOT/tools/zephyr-cli/cli" balances
"$REPO_ROOT/tools/zephyr-cli/cli" mine start --threads 4
```
