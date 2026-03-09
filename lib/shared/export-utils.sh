#!/bin/bash
# Shared export utility for safe function exports
#
# Provides protected_export which guards export -f calls against undefined
# functions. This prevents failures under set -euo pipefail when a function
# is conditionally defined (e.g., from an optional dependency).
#
# Usage:
#   source /tmp/build-scripts/shared/export-utils.sh
#   protected_export func1 func2 func3

# Prevent multiple sourcing
if [ -n "${_SHARED_EXPORT_UTILS_LOADED:-}" ]; then
    return 0
fi
_SHARED_EXPORT_UTILS_LOADED=1

# ============================================================================
# protected_export - Export functions only if they are defined
#
# Arguments:
#   $@ - One or more function names to export
#
# Returns:
#   0 always (undefined functions are silently skipped)
#
# Example:
#   protected_export log_message log_info log_debug
# ============================================================================
protected_export() {
    local fn
    for fn in "$@"; do
        if declare -f "$fn" >/dev/null 2>&1; then
            export -f "${fn?}"
        fi
    done
    return 0
}

# Self-export
export -f protected_export
