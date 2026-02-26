#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

exec "$REPO_ROOT/tools/zephyr-cli/cli" setup-state "$@"
