#!/usr/bin/env bash
# Shared runtime PATH utilities
#
# Provides safe_add_to_path for runtime PATH management. Build-time
# path-utils (lib/base/path-utils.sh) sources this and extends it with
# add_to_system_path which writes to /etc/environment.
#
# Dependencies:
#   log_warning, log_message from shared/logging.sh (must be sourced first)

# Prevent multiple sourcing
if [ -n "${_SHARED_PATH_UTILS_LOADED:-}" ]; then
    return 0
fi
_SHARED_PATH_UTILS_LOADED=1

# ============================================================================
# safe_add_to_path - Securely add directory to runtime PATH with validation
# ============================================================================
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

    # Log only if verbose mode is enabled (disabled by default to keep output clean)
    if [ "${VERBOSE_PATH_NOTICES:-}" = "true" ]; then
        log_message "Added to PATH: $dir"
    fi
    return 0
}

# Export function
export -f safe_add_to_path
