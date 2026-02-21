# fake-oracle

A lightweight HTTP server that simulates a price oracle for the Zephyr devnet. It provides cryptographically signed ZEPH/USD price data that the daemon uses to calculate reserve ratios and maintain algorithmic stability.

## Quick Start

```bash
node server.js
# or
ORACLE_PORT=5555 node server.js
```

No dependencies beyond Node.js — uses only built-in modules (`http`, `crypto`, `fs`).

## Configuration

| Environment Variable | Default | Description |
|---|---|---|
| `ORACLE_PORT` | `5555` | HTTP server port |

The default spot price on startup is `1500000000000` atomic units ($1.50 USD, where 1 USD = 10^12 atomic units).

## API

### `GET /price/?timestamp=<ts>&version=<hf>`

Returns a signed pricing record.

| Parameter | Default | Description |
|---|---|---|
| `timestamp` | `0` | Unix timestamp |
| `version` | `11` | Hard fork version |

```json
{
  "pr": {
    "spot": 1500000000000,
  "moving_average": 1500000000000,
    "stable": 0,
    "stable_ma": 0,
    "reserve": 0,
    "reserve_ma": 0,
    "reserve_ratio": 0,
    "reserve_ratio_ma": 0,
    "yield_price": 0,
    "timestamp": 0,
    "signature": "hex-encoded-sha256-rsa-signature"
  },
  "status": "OK"
}
```

Only `spot` and `signature` come from the oracle — the daemon recalculates `stable`, `reserve`, `reserve_ratio`, and `yield_price` from circulating supply.

### `POST /set-price`

Updates the in-memory spot price.

```bash
curl -X POST http://127.0.0.1:5555/set-price \
  -H 'Content-Type: application/json' \
  -d '{"spot": 2500000000000}'
```

```json
{ "status": "OK", "spot": 2500000000000 }
```

### `GET /status`

Health check returning current spot price and server state.

```json
{ "spot": 1500000000000, "status": "running" }
```

## Signing

Pricing records are signed with SHA256-RSA using the bundled `oracle_private.pem` key. The message signed is `JSON.stringify({ spot, timestamp })`. The matching `oracle_public.pem` is used by the daemon for verification.

Both keys are committed to the repo — this is devnet-only and not suitable for production.

## Integration

The oracle is started automatically by the fresh-devnet bootstrap via overmind:

```
oracle: ORACLE_PORT=$ORACLE_PORT node $REPO_ROOT/tools/fake-oracle/server.js
```

Price can be controlled via:
- `tools/fresh-devnet/commands/set-price.sh <usd_value>`
- `tools/zephyr-cli/cli price <usd_value>`
- Direct `POST /set-price` calls
