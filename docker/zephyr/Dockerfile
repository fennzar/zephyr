# Zephyr node + wallet-rpc (single image, mode selected via ZEPHYR_MODE env)
#
# Multi-stage: builds from source inside Docker so host/container libs always match.
# Build context must be the repo root (compose uses context: ..)
#
# Run as node:
#   docker run -e ZEPHYR_MODE=node zephyr-devnet --devnet --rpc-bind-port=47767 ...
#
# Run as wallet:
#   docker run -e ZEPHYR_MODE=wallet zephyr-devnet --rpc-bind-port=48769 ...

# ── Builder ──────────────────────────────────────────────────────────────────
FROM ubuntu:24.04 AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    pkg-config \
    libboost-all-dev \
    libssl-dev \
    libzmq3-dev \
    libsodium-dev \
    libreadline-dev \
    libunbound-dev \
    libhidapi-dev \
    libprotobuf-dev \
    protobuf-compiler \
    libusb-1.0-0-dev \
    libudev-dev \
    libevent-dev \
    git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY . .

ARG DEVNET_MODE=custom
ARG BUILD_JOBS=1

RUN mkdir -p build/devnet && cd build/devnet \
    && cmake /src -DCMAKE_BUILD_TYPE=Release \
        $([ "$DEVNET_MODE" = "mirror" ] && echo "-DDEVNET_MIRROR_SUPPLY=ON") \
    && make -j${BUILD_JOBS} daemon wallet_rpc_server

# ── Runtime ──────────────────────────────────────────────────────────────────
FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    libboost-chrono1.83.0 \
    libboost-filesystem1.83.0 \
    libboost-program-options1.83.0 \
    libboost-thread1.83.0 \
    libboost-serialization1.83.0 \
    libzmq5 \
    libsodium23 \
    libreadline8t64 \
    libhidapi-libusb0 \
    libunbound8 \
    libssl3t64 \
    libprotobuf32t64 \
    libusb-1.0-0 \
    libevent-2.1-7t64 \
    libudev1 \
    curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/build/devnet/bin/zephyrd /src/build/devnet/bin/zephyr-wallet-rpc /usr/local/bin/
COPY docker/zephyr/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh /usr/local/bin/zephyrd /usr/local/bin/zephyr-wallet-rpc

ENV ZEPHYR_MODE=node

ENTRYPOINT ["/entrypoint.sh"]
