#!/usr/bin/env bash
# Path Utilities for Container Build System
# Version: 1.0.0
#
# Description:
#   Provides utilities for manipulating system PATH in /etc/environment.
#   Handles safe updates to ensure paths are added only once.
#
# Usage:
#   source /tmp/build-scripts/base/path-utils.sh
#   add_to_system_path "/cache/cargo/bin"
#   add_to_system_path "/opt/pipx/bin" "/custom/path"
#
# Functions:
#   add_to_system_path - Add a directory to system PATH in /etc/environment

# Prevent multiple sourcing
if [ -n "${PATH_UTILS_LOADED:-}" ]; then
    return 0
fi
readonly PATH_UTILS_LOADED=1

set -euo pipefail

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
        existing_path=$(command grep "^PATH=" "$environment_file" | cut -d'"' -f2)

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

# ============================================================================
# safe_add_to_path - Securely add directory to runtime PATH with validation
# ============================================================================
#
# Description:
#   Validates a directory before adding it to the current shell's PATH.
#   Performs security checks to prevent PATH hijacking attacks.
#
# Security Checks:
#   1. Directory exists and is actually a directory
#   2. Directory is not world-writable (prevents unauthorized modifications)
#   3. Directory is owned by root or current user (prevents privilege escalation)
#   4. Path is added to beginning of PATH for precedence
#
# Arguments:
#   $1 - Path to add to runtime PATH (required)
#
# Returns:
#   0 on success (path added), 1 on validation failure (path not added)
#
# Example:
#   safe_add_to_path "/usr/local/go/bin"
#   safe_add_to_path "$HOME/.cargo/bin"
#
# Notes:
#   - This modifies the current shell's PATH, not /etc/environment
#   - Use add_to_system_path() for persistent PATH changes
#   - Validation failures are logged but don't stop execution
#   - Prevents duplicate entries
#
safe_add_to_path() {
    local dir="$1"

    # Validate input
    if [ -z "$dir" ]; then
        log_warning "safe_add_to_path: No directory specified"
        return 1
    fi

    # Check if directory exists
    if [ ! -d "$dir" ]; then
        log_warning "safe_add_to_path: Directory does not exist: $dir"
        return 1
    fi

    # Check if world-writable (security risk)
    local perms
    perms=$(stat -c %a "$dir" 2>/dev/null || stat -f %Lp "$dir" 2>/dev/null || echo "000")

    # Check last digit for world-writable (e.g., 777, 757, etc.)
    local world_perm="${perms: -1}"
    if [ "$((world_perm & 2))" -ne 0 ]; then
        log_warning "safe_add_to_path: Directory is world-writable (security risk): $dir"
        log_warning "  Permissions: $perms"
        return 1
    fi

    # Check ownership (must be root or current user)
    local owner
    owner=$(stat -c %U "$dir" 2>/dev/null || stat -f %Su "$dir" 2>/dev/null || echo "unknown")

    if [ "$owner" != "root" ] && [ "$owner" != "${USER:-$(whoami)}" ]; then
        log_warning "safe_add_to_path: Directory not owned by root or current user: $dir"
        log_warning "  Owner: $owner"
        return 1
    fi

    # Check if already in PATH
    if [[ ":$PATH:" == *":${dir}:"* ]]; then
        # Already in PATH, no need to add
        return 0
    fi

    # Add to PATH (prepend for precedence)
    export PATH="$dir:$PATH"

    log_message "Added to PATH: $dir"
    return 0
}

# Export function for use in feature scripts
export -f add_to_system_path
export -f safe_add_to_path
