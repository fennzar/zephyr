#!/bin/bash
set -e

case "${ZEPHYR_MODE}" in
  node)
    exec zephyrd "$@"
    ;;
  wallet)
    exec zephyr-wallet-rpc "$@"
    ;;
  *)
    echo "Error: ZEPHYR_MODE must be 'node' or 'wallet' (got '${ZEPHYR_MODE}')" >&2
    exit 1
    ;;
esac
