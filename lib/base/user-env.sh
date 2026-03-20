#!/bin/bash
# User identity resolution
# Sources /tmp/build-env or falls back to user detection from the system.
#
# Exports: USERNAME, USER_UID, USER_GID, WORKING_DIR
# Include guard: _USER_ENV_LOADED

# Prevent multiple sourcing
if [ -n "${_USER_ENV_LOADED:-}" ]; then
    return 0
fi
_USER_ENV_LOADED=1

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
