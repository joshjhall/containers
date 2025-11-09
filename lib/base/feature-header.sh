#!/bin/bash
# Standard header for feature scripts
# Source this at the beginning of each feature script to get consistent user handling
#
# This script provides:
# 1. Environment validation (Bash version, Debian/Ubuntu detection)
# 2. Consistent user UID/GID handling across all features
# 3. Protection against incompatible environments
#
# How it works:
# 1. Validates Bash version (requires 5.0+)
# 2. Detects Debian/Ubuntu version (supports Debian 11+, Ubuntu 20.04+)
# 3. Gets parameters with sensible defaults (developer user, UID/GID 1000)
# 4. Checks if /tmp/build-env exists (created by user.sh if UID/GID conflicts occurred)
# 5. If conflicts occurred, uses ACTUAL_UID/ACTUAL_GID from build-env
# 6. Exports USERNAME, USER_UID, USER_GID for use in the feature script
#
# This ensures feature scripts always use the correct UID/GID, even if the
# base image already had a user with UID 1000.

# ============================================================================
# Environment Validation
# ============================================================================

# Check Bash version (require 5.0+)
if [ -z "${BASH_VERSION}" ]; then
    echo "Error: This script requires Bash, but appears to be running in a different shell"
    exit 1
fi

BASH_MAJOR_VERSION="${BASH_VERSION%%.*}"
if [ "${BASH_MAJOR_VERSION}" -lt 5 ]; then
    echo "Error: This script requires Bash 5.0 or newer"
    echo "Current version: ${BASH_VERSION}"
    echo "Please use a base image with a newer Bash version"
    exit 1
fi

# Check for Debian-based system
if [ ! -f /etc/os-release ]; then
    echo "Error: Cannot determine OS version - /etc/os-release not found"
    exit 1
fi

# Source OS information
source /etc/os-release

# Validate OS type
if [ "${ID}" != "debian" ] && [ "${ID_LIKE}" != "debian" ]; then
    echo "Error: This script requires a Debian-based system"
    echo "Current OS: ${ID} ${VERSION_ID}"
    echo "These scripts use apt package manager and Debian-specific configurations"
    exit 1
fi

# Detect Debian/Ubuntu version for logging and export for feature scripts
if [ "${ID}" = "debian" ]; then
    # Extract major version number
    DEBIAN_VERSION="${VERSION_ID%%.*}"
    export DEBIAN_VERSION
    echo "Detected Debian ${VERSION_ID} (${VERSION_CODENAME:-unknown})"

    # Note: This build system supports Debian 11 (Bullseye), 12 (Bookworm), and 13 (Trixie)
    # Version-specific package handling is done in apt-utils.sh using apt_install_conditional
elif [ "${ID}" = "ubuntu" ]; then
    UBUNTU_VERSION="${VERSION_ID%%.*}"
    export UBUNTU_VERSION
    echo "Detected Ubuntu ${VERSION_ID}"

    # Note: Ubuntu 20.04+ is supported. Some features use version detection for compatibility
fi

# ============================================================================
# User Handling
# ============================================================================

# Source actual values from user creation
if [ -f /tmp/build-env ]; then
    source /tmp/build-env
    # Use values from build-env
    USERNAME="${USERNAME:-developer}"
    USER_UID="${ACTUAL_UID:-1000}"
    USER_GID="${ACTUAL_GID:-1000}"
    WORKING_DIR="${WORKING_DIR:-/workspace/project}"
    echo "Using values from build-env: ${USERNAME} (${USER_UID}:${USER_GID}) in ${WORKING_DIR}"
else
    # Fallback if build-env doesn't exist (shouldn't happen in normal builds)
    echo "Warning: /tmp/build-env not found, attempting to detect existing user"

    # Try to find a non-root user with a home directory
    DETECTED_USER=""
    for home_dir in /home/*; do
        if [ -d "$home_dir" ]; then
            potential_user=$(basename "$home_dir")
            # Skip if it's not a real user
            if id "$potential_user" >/dev/null 2>&1; then
                DETECTED_USER="$potential_user"
                break
            fi
        fi
    done

    if [ -n "$DETECTED_USER" ]; then
        USERNAME="$DETECTED_USER"
        USER_UID=$(id -u "$DETECTED_USER")
        USER_GID=$(id -g "$DETECTED_USER")
        WORKING_DIR="${WORKING_DIR:-/workspace/project}"
        echo "Detected existing user: ${USERNAME} (${USER_UID}:${USER_GID}) in ${WORKING_DIR}"
    else
        # Ultimate fallback to defaults
        USERNAME="${USERNAME:-developer}"
        USER_UID="${USER_UID:-1000}"
        USER_GID="${USER_GID:-1000}"
        WORKING_DIR="${WORKING_DIR:-/workspace/project}"
        echo "No existing user detected, using defaults: ${USERNAME} (${USER_UID}:${USER_GID}) in ${WORKING_DIR}"
    fi
fi

# Export for use in subscripts
export USERNAME USER_UID USER_GID WORKING_DIR

# ============================================================================
# Logging Support
# ============================================================================
# Source logging functions if available
if [ -f /tmp/build-scripts/base/logging.sh ]; then
    source /tmp/build-scripts/base/logging.sh
fi

# Source bashrc helper functions if available
if [ -f /tmp/build-scripts/base/bashrc-helpers.sh ]; then
    source /tmp/build-scripts/base/bashrc-helpers.sh
fi

# ============================================================================
# Helper Functions
# ============================================================================

# Create a symlink with proper permissions for non-root execution
# Usage: create_symlink <target> <link_name> [description]
# Example: create_symlink /opt/go/bin/go /usr/local/bin/go "Go compiler"
create_symlink() {
    local target="$1"
    local link_name="$2"
    local description="${3:-symlink}"

    if [ -z "$target" ] || [ -z "$link_name" ]; then
        log_error "create_symlink requires target and link_name arguments"
        return 1
    fi

    # Create the symlink
    log_command "Creating $description symlink" \
        ln -sf "$target" "$link_name"

    # Ensure the symlink itself has proper permissions
    # Note: chmod on a symlink affects the target, not the link
    # But we can verify the target is accessible
    if [ -e "$target" ]; then
        # If target is a file, ensure it's executable
        if [ -f "$target" ]; then
            log_command "Ensuring $description is executable" \
                chmod +x "$target"
        fi
        log_message "Created symlink: $link_name -> $target"
    else
        log_warning "Symlink target does not exist: $target"
    fi

    # Verify the symlink works
    if [ -L "$link_name" ]; then
        local link_target
        link_target=$(readlink -f "$link_name")
        if [ -e "$link_target" ]; then
            log_message "✓ Symlink verified: $link_name -> $link_target"
        else
            log_warning "✗ Symlink broken: $link_name -> $link_target"
        fi
    else
        log_error "Failed to create symlink: $link_name"
    fi
}

# ============================================================================
# Secure Temporary Directory Management
# ============================================================================

# create_secure_temp_dir - Create a secure temporary directory with automatic cleanup
#
# Usage:
#   TEMP_DIR=$(create_secure_temp_dir)
#   # Use $TEMP_DIR for temporary files
#   # Automatic cleanup happens on script exit (via trap)
#
# Security benefits:
#   - Unique directory per process (prevents collisions)
#   - Restrictive permissions (700 - owner only)
#   - Automatic cleanup on exit (prevents leftover files)
#   - Protection against symlink attacks
#
# Note: This function sets up a trap for cleanup. If your script already
# uses EXIT traps, they will be chained together.
create_secure_temp_dir() {
    local temp_dir
    temp_dir=$(mktemp -d -t build-XXXXXXXXXX)

    if [ -z "$temp_dir" ] || [ ! -d "$temp_dir" ]; then
        log_error "Failed to create secure temporary directory"
        return 1
    fi

    # Set restrictive permissions (owner only)
    chmod 700 "$temp_dir"

    # Set up automatic cleanup on script exit
    # shellcheck disable=SC2064  # We want variables expanded now, not at trap time
    trap "rm -rf '$temp_dir'" EXIT

    # Log to stderr so it doesn't interfere with command substitution
    log_message "Created secure temporary directory: $temp_dir" >&2
    echo "$temp_dir"
}
