#!/bin/bash
# Feature utility functions
# Provides helper functions used by feature installation scripts.
#
# Functions: create_symlink(target, link_name, [description])
#            create_secure_temp_dir() -> path
# Dependencies: logging functions + register_cleanup (sourced before this)
# Include guard: _FEATURE_UTILS_LOADED

# Prevent multiple sourcing
if [ -n "${_FEATURE_UTILS_LOADED:-}" ]; then
    return 0
fi
_FEATURE_UTILS_LOADED=1

# ============================================================================
# Symlink Creation
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

# create_secure_temp_dir - Create a secure temporary directory
#
# Usage:
#   TEMP_DIR=$(create_secure_temp_dir)
#   cd "$TEMP_DIR"
#   # Use temporary files
#   cd /
#   # Cleanup happens automatically via cleanup-handler.sh trap
#
# Security benefits:
#   - Unique directory per process (prevents collisions)
#   - Controlled permissions (755 - owner write, all read/execute)
#   - Protection against symlink attacks
#   - Allows non-root users to read/execute files (needed for su/sudo scenarios)
#
# Note: Cleanup is handled by the cleanup_on_interrupt trap handler,
# not by this function (to avoid subshell trap issues).
create_secure_temp_dir() {
    local temp_dir
    temp_dir=$(mktemp -d -t build-XXXXXXXXXX)

    if [ -z "$temp_dir" ] || [ ! -d "$temp_dir" ]; then
        log_error "Failed to create secure temporary directory"
        return 1
    fi

    # Set permissions: owner rwx, group rx, others rx (755)
    # This allows non-root users to read/execute files but not write
    chmod 755 "$temp_dir"

    # Register for automatic cleanup on interruption
    register_cleanup "$temp_dir"

    # Log to stderr so it doesn't interfere with command substitution
    log_message "Created secure temporary directory: $temp_dir" >&2
    echo "$temp_dir"
}
