#!/usr/bin/env bash
# Cache Directory Utilities for Container Build System
# Version: 1.0.0
# Provides shared utilities for creating and managing cache directories
#
# All functions use the cu_ prefix to avoid namespace collisions.
#
# Features:
# - Atomic directory creation with correct ownership
# - Support for single or multiple cache directories
# - Consistent permissions (0755) across all caches
# - Integration with logging system
#
# Dependencies:
# - lib/base/logging.sh (must be sourced before this file)
# - USER_UID and USER_GID environment variables must be set
#
# Usage:
#   source /tmp/build-scripts/base/cache-utils.sh
#   create_language_cache "pip"
#   create_language_caches "npm" "yarn" "pnpm"

# Prevent multiple sourcing
if [ -n "${_CACHE_UTILS_LOADED:-}" ]; then
    return 0
fi
_CACHE_UTILS_LOADED=1

set -euo pipefail

# Create a single cache directory with correct ownership
# Args:
#   $1: cache_name - Name of the cache (e.g., "pip", "npm")
#   $2: base_path (optional) - Base path for cache (default: /cache)
# Returns:
#   Echoes the full path to the created cache directory
# Example:
#   pip_cache=$(create_language_cache "pip")
#   echo "PIP cache at: $pip_cache"
create_language_cache() {
    local cache_name="$1"
    local base_path="${2:-/cache}"
    local cache_path="${base_path}/${cache_name}"

    # Validate required environment variables
    if [[ -z "${USER_UID:-}" ]] || [[ -z "${USER_GID:-}" ]]; then
        log_error "USER_UID and USER_GID must be set before creating cache directories"
        return 1
    fi

    # Create cache directory with atomic ownership setting
    log_command "Creating ${cache_name} cache directory" \
        bash -c "install -d -m 0755 -o '${USER_UID}' -g '${USER_GID}' '${cache_path}'"

    echo "$cache_path"
}

# Create multiple cache directories with correct ownership
# Args:
#   $@: cache_names - Names of caches to create (e.g., "pip" "poetry" "pipx")
# Returns:
#   0 on success, 1 on failure
# Example:
#   create_language_caches "pip" "poetry" "pipx"
create_language_caches() {
    local cache_names=("$@")

    if [[ ${#cache_names[@]} -eq 0 ]]; then
        log_error "At least one cache name must be provided"
        return 1
    fi

    # Build install command for all directories at once (atomic operation)
    local cu_dirs=()
    for cache_name in "${cache_names[@]}"; do
        cu_dirs+=("/cache/${cache_name}")
    done

    # Create all cache directories in a single command
    log_command "Creating cache directories: ${cache_names[*]}" \
        bash -c "install -d -m 0755 -o '${USER_UID}' -g '${USER_GID}' ${cu_dirs[*]}"
}

# Create cache directories with custom paths
# Useful when cache directories aren't all under /cache
# Args:
#   $@: full_paths - Full paths to cache directories
# Returns:
#   0 on success, 1 on failure
# Example:
#   create_cache_directories "/cache/pip" "/opt/pipx" "/cache/poetry"
create_cache_directories() {
    local paths=("$@")

    if [[ ${#paths[@]} -eq 0 ]]; then
        log_error "At least one path must be provided"
        return 1
    fi

    # Validate required environment variables
    if [[ -z "${USER_UID:-}" ]] || [[ -z "${USER_GID:-}" ]]; then
        log_error "USER_UID and USER_GID must be set before creating cache directories"
        return 1
    fi

    # Create all directories in a single command
    log_command "Creating cache directories" \
        bash -c "install -d -m 0755 -o '${USER_UID}' -g '${USER_GID}' ${paths[*]}"
}

# Export functions for use in feature scripts
export -f create_language_cache
export -f create_language_caches
export -f create_cache_directories
