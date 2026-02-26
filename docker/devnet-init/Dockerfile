# DEVNET bootstrap container — runs zephyr-cli devnet init, then exits.
#
# Creates gov/miner/test wallets, runs minting sequence, saves checkpoint.
# Consumer-specific wallets (bridge, engine, cex) are NOT created here.

FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir requests

COPY tools/zephyr-cli/ /opt/zephyr-cli/
COPY utils/python-rpc/ /opt/python-rpc/

COPY docker/devnet-init/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh /opt/zephyr-cli/cli

ENTRYPOINT ["/entrypoint.sh"]
