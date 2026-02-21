#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

ZEPHYR_CLI="$REPO_ROOT/tools/zephyr-cli/cli"

show_only="${1:-}"

if [[ "$show_only" == "--show" ]]; then
    if [[ -f "$CHECKPOINT_FILE" ]]; then
        echo "Checkpoint height: $(cat "$CHECKPOINT_FILE")"
        if [[ -f "$CHECKPOINT_INFO_FILE" ]]; then
            echo "Checkpoint info:"
            cat "$CHECKPOINT_INFO_FILE"
        fi
    else
        echo "No checkpoint saved"
    fi
    exit 0
fi

# Get current height
if [[ -x "$ZEPHYR_CLI" ]]; then
    height=$("$ZEPHYR_CLI" height 2>/dev/null) || height="0"
else
    height=$(get_height)
fi

if [[ "$height" == "0" ]]; then
    echo "Error: Could not get current height from node1"
    exit 1
fi

# Get reserve info for reference
reserve_info=$(get_reserve_info 2>/dev/null)

# Save checkpoint height
mkdir -p "$(dirname "$CHECKPOINT_FILE")"
echo "$height" > "$CHECKPOINT_FILE"

# Save checkpoint info with reserve data
timestamp=$(date -Iseconds)
python3 -c "
import sys, json
try:
    ri = json.loads('''$reserve_info''').get('result', {})
    info = {
        'height': $height,
        'timestamp': '$timestamp',
        'reserve_info': {
            'reserve_ratio': ri.get('reserve_ratio', 'unknown'),
            'num_reserves': float(ri.get('num_reserves', 0)) / 1e12,
            'num_stables': float(ri.get('num_stables', 0)) / 1e12
        }
    }
except:
    info = {'height': $height, 'timestamp': '$timestamp', 'reserve_info': {}}
print(json.dumps(info, indent=2))
" > "$CHECKPOINT_INFO_FILE" 2>/dev/null

echo "Checkpoint saved at height $height"
echo "  File: $CHECKPOINT_FILE"
