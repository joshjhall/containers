#!/bin/bash
# Shared ANSI color constants
#
# Source this instead of redefining colors per-file.
# Uses an include guard to prevent multiple sourcing.
#
# Standard colors: RED, GREEN, YELLOW, BLUE, NC
# Extended colors: CYAN, BOLD

# Prevent multiple sourcing
if [ -n "${_SHARED_COLORS_LOADED:-}" ]; then
    return 0
fi
_SHARED_COLORS_LOADED=1

export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export CYAN='\033[0;36m'
export BOLD='\033[1m'
export NC='\033[0m'
