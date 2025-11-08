#!/bin/bash
# Common utilities for bin scripts
#
# Description:
#   Shared functions used across version management scripts.
#   Provides color codes, logging, and path resolution.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
#   log_info "Starting process..."
#   log_success "Process completed!"

# Header guard to prevent multiple sourcing
if [ -n "${_BIN_LIB_COMMON_SH_INCLUDED:-}" ]; then
    return 0
fi
readonly _BIN_LIB_COMMON_SH_INCLUDED=1

set -euo pipefail

# ============================================================================
# Color Codes
# ============================================================================

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# ============================================================================
# Logging Functions
# ============================================================================

# log_info - Log informational message in blue
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

# log_success - Log success message in green
log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

# log_warning - Log warning message in yellow
log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

# log_error - Log error message in red to stderr
log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

# ============================================================================
# Path Resolution
# ============================================================================

# get_script_dir - Get the directory containing the calling script
#
# Usage:
#   SCRIPT_DIR=$(get_script_dir)
#
# Note: This resolves symlinks and returns the real directory path
get_script_dir() {
    local source="${BASH_SOURCE[1]}"
    local dir=""

    # Resolve $source until the file is no longer a symlink
    while [ -L "$source" ]; do
        dir=$(cd -P "$(dirname "$source")" && pwd)
        source=$(readlink "$source")
        [[ $source != /* ]] && source="$dir/$source"
    done

    cd -P "$(dirname "$source")" && pwd
}

# get_project_root - Get the project root directory
#
# Usage:
#   PROJECT_ROOT=$(get_project_root)
#   PROJECT_ROOT="${PROJECT_ROOT_OVERRIDE:-$(get_project_root)}"
#
# Returns: The parent directory of the bin/ directory
get_project_root() {
    local script_dir
    script_dir=$(get_script_dir)

    # Walk up the directory tree to find bin/
    while [[ "$script_dir" != "/" ]]; do
        if [[ "$(basename "$script_dir")" == "bin" ]]; then
            dirname "$script_dir"
            return 0
        fi
        script_dir=$(dirname "$script_dir")
    done

    # Fallback: assume we're in bin/ or bin/subdir
    local current_dir
    current_dir=$(get_script_dir)

    if [[ "$(basename "$current_dir")" == "bin" ]]; then
        dirname "$current_dir"
    elif [[ "$(basename "$(dirname "$current_dir")")" == "bin" ]]; then
        dirname "$(dirname "$current_dir")"
    else
        # Last resort: go up one level
        dirname "$current_dir"
    fi
}

# ============================================================================
# Utility Functions
# ============================================================================

# require_command - Check if required command is available
#
# Arguments:
#   $1 - Command name
#
# Returns:
#   0 if available, exits with error if not
require_command() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_error "Required command not found: $cmd"
        exit 1
    fi
}

# get_current_date - Get current date in YYYY-MM-DD format
get_current_date() {
    date +%Y-%m-%d
}
