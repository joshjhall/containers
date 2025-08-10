#!/bin/bash
# Wrapper to run feature scripts with actual UID/GID values
set -euo pipefail

FEATURE_SCRIPT="$1"
shift

# Source the actual UID/GID values if they exist
if [ -f /tmp/build-env ]; then
    source /tmp/build-env
    # Override the passed UID/GID with actual values
    USERNAME="${1:-developer}"
    exec "$FEATURE_SCRIPT" "$USERNAME" "${ACTUAL_UID:-$2}" "${ACTUAL_GID:-$3}"
else
    # Fallback to passed values
    exec "$FEATURE_SCRIPT" "$@"
fi
