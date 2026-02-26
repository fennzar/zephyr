#!/bin/bash
set -euo pipefail

exec /opt/zephyr-cli/cli devnet init \
    --oracle-price "${ORACLE_PRICE:-2.0}" \
    --mode "${DEVNET_MODE:-custom}" \
    --target-rr "${TARGET_RR:-7.0}" \
    --zsd-limit "${ZSD_MINT_LIMIT:-450000}" \
    --checkpoint-file "${CHECKPOINT_FILE:-/checkpoint/height}" \
    --mining-threads "${MINING_THREADS:-2}" \
    "$@"
