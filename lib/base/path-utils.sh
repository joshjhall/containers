#!/usr/bin/env bash
# Path Utilities for Container Build System
# Version: 1.0.0
#
# Description:
#   Provides utilities for manipulating system PATH in /etc/environment.
#   Sources shared/path-utils.sh for runtime safe_add_to_path and extends
#   it with add_to_system_path for build-time /etc/environment writes.
#
# Usage:
#   source /tmp/build-scripts/base/path-utils.sh
#   add_to_system_path "/cache/cargo/bin"
#   add_to_system_path "/opt/pipx/bin" "/custom/path"
#
# Functions:
#   safe_add_to_path   - (from shared) Securely add directory to runtime PATH
#   add_to_system_path - Add a directory to system PATH in /etc/environment

# Prevent multiple sourcing
if [ -n "${PATH_UTILS_LOADED:-}" ]; then
    return 0
fi
readonly PATH_UTILS_LOADED=1

set -euo pipefail

# Source shared path utilities (safe_add_to_path)
# shellcheck source=lib/shared/path-utils.sh
if [ -f "/tmp/build-scripts/shared/path-utils.sh" ]; then
    source "/tmp/build-scripts/shared/path-utils.sh"
elif [ -f "$(dirname "${BASH_SOURCE[0]}")/../shared/path-utils.sh" ]; then
    source "$(dirname "${BASH_SOURCE[0]}")/../shared/path-utils.sh"
fi

# Default system PATH if /etc/environment doesn't exist
readonly DEFAULT_SYSTEM_PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"

# ============================================================================
# add_to_system_path - Add directory to /etc/environment PATH
# ============================================================================
#
# Description:
#   Adds a directory to the system PATH in /etc/environment if not already present.
#   Safely reads existing PATH, removes duplicates, and writes back atomically.
#
# Arguments:
#   $1 - Path to add to system PATH (required)
#   $2 - Custom base PATH (optional, defaults to existing PATH or DEFAULT_SYSTEM_PATH)
#
# Returns:
#   0 on success, 1 on error
#
# Example:
#   add_to_system_path "/cache/cargo/bin"
#   add_to_system_path "/opt/pipx/bin" "/custom/path"
#
# Notes:
#   - Uses log_command from feature-header.sh for logging
#   - Creates /etc/environment if it doesn't exist
#   - Preserves existing PATH entries
#   - Prevents duplicate path entries
#
add_to_system_path() {
    local new_path="$1"
    local custom_base_path="${2:-}"
    local environment_file="/etc/environment"
    local existing_path=""
    local updated_path=""

    # Validate input
    if [ -z "$new_path" ]; then
        log_error "add_to_system_path requires a path argument"
        return 1
    fi

    # Read existing PATH from /etc/environment or use default
    # Use 'command grep' to bypass any aliases (e.g., grep='rg' from dev-tools)
    if [ -f "$environment_file" ] && command grep -q "^PATH=" "$environment_file"; then
        # Extract existing PATH
        existing_path=$(command grep "^PATH=" "$environment_file" | command cut -d'"' -f2)

        # Remove the PATH line from the file
        log_command "Removing existing PATH from /etc/environment" \
            bash -c "(command grep -v '^PATH=' '$environment_file' || true) > '${environment_file}.tmp' && command mv '${environment_file}.tmp' '$environment_file'"
    else
        # Use custom base path if provided, otherwise use default
        if [ -n "$custom_base_path" ]; then
            existing_path="$custom_base_path"
        else
            existing_path="$DEFAULT_SYSTEM_PATH"
        fi
    fi

    # Add new path if not already present (check with colons on both sides to avoid partial matches)
    updated_path="$existing_path"
    if [[ ":$updated_path:" != *":${new_path}:"* ]]; then
        updated_path="${updated_path}:${new_path}"
    fi

    # Write updated PATH back to /etc/environment
    log_command "Writing updated PATH to /etc/environment (added: ${new_path})" \
        bash -c "echo 'PATH=\"$updated_path\"' >> '$environment_file'"

    return 0
}

# Export function for use in feature scripts
export -f add_to_system_path
