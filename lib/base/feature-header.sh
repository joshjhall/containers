#!/bin/bash
# Standard header for feature scripts
# Source this at the beginning of each feature script to get consistent user handling
#
# This script provides:
# 1. Environment validation (Bash version, Debian compatibility)
# 2. Consistent user UID/GID handling across all features
# 3. Protection against incompatible environments
#
# How it works:
# 1. Validates Bash version (requires 5.0+)
# 2. Validates Debian version (requires bookworm/12+ or newer)
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

# Check Debian version (require bookworm/12+ or newer)
if [ "${ID}" = "debian" ]; then
    # Extract major version number
    DEBIAN_VERSION="${VERSION_ID%%.*}"
    if [ "${DEBIAN_VERSION}" -lt 12 ]; then
        echo "Error: This script requires Debian 12 (bookworm) or newer"
        echo "Current version: Debian ${VERSION_ID} (${VERSION_CODENAME:-unknown})"
        echo "Many features depend on packages only available in bookworm+"
        exit 1
    fi
elif [ "${ID}" = "ubuntu" ]; then
    # Ubuntu 22.04+ is roughly equivalent to Debian bookworm
    UBUNTU_VERSION="${VERSION_ID%%.*}"
    if [ "${UBUNTU_VERSION}" -lt 22 ]; then
        echo "Error: This script requires Ubuntu 22.04 or newer"
        echo "Current version: Ubuntu ${VERSION_ID}"
        exit 1
    fi
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
        local link_target=$(readlink -f "$link_name")
        if [ -e "$link_target" ]; then
            log_message "✓ Symlink verified: $link_name -> $link_target"
        else
            log_warning "✗ Symlink broken: $link_name -> $link_target"
        fi
    else
        log_error "Failed to create symlink: $link_name"
    fi
}
