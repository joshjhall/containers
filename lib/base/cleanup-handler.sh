#!/bin/bash
# Interrupted build cleanup handler
#
# Provides automatic cleanup of temporary files and directories when a
# feature build is interrupted (Ctrl+C, TERM signal) or exits with an error.
# Items are cleaned up in reverse registration order (LIFO).
#
# Functions provided:
#   cleanup_on_interrupt  - Trap handler that processes cleanup items
#   register_cleanup      - Register a file/directory for cleanup
#   unregister_cleanup    - Remove an item from the cleanup list
#
# This is a sub-module of feature-header.sh — source feature-header.sh
# instead of this file directly to get the full feature header system.

# Prevent multiple sourcing
if [ -n "${_CLEANUP_HANDLER_LOADED:-}" ]; then
    return 0
fi
_CLEANUP_HANDLER_LOADED=1

# Global array to track cleanup actions for interrupted builds
declare -a _FEATURE_CLEANUP_ITEMS=()

# cleanup_on_interrupt - Cleanup handler called on EXIT/INT/TERM
#
# This function is automatically called when:
# - Feature script exits normally (EXIT)
# - User interrupts build with Ctrl+C (INT)
# - Process receives termination signal (TERM)
#
# It processes all registered cleanup items in reverse order (LIFO).
cleanup_on_interrupt() {
    local exit_code=$?

    # Check if array is set and has elements (safe with set -u)
    if [[ -v _FEATURE_CLEANUP_ITEMS ]] && [ ${#_FEATURE_CLEANUP_ITEMS[@]} -gt 0 ]; then
        echo "=== Cleaning up interrupted build ===" >&2

        # Process cleanup items in reverse order (LIFO - last in, first out)
        local i
        for ((i=${#_FEATURE_CLEANUP_ITEMS[@]}-1; i>=0; i--)); do
            local cleanup_item="${_FEATURE_CLEANUP_ITEMS[i]}"

            # Check if it's a directory
            if [ -d "$cleanup_item" ]; then
                echo "Removing temporary directory: $cleanup_item" >&2
                command rm -rf "$cleanup_item" 2>/dev/null || true
            # Check if it's a file
            elif [ -f "$cleanup_item" ]; then
                echo "Removing temporary file: $cleanup_item" >&2
                command rm -f "$cleanup_item" 2>/dev/null || true
            fi
        done

        echo "=== Cleanup completed ===" >&2
    fi

    # Preserve original exit code
    exit $exit_code
}

# register_cleanup - Register a file or directory for cleanup
#
# Usage:
#   register_cleanup "/tmp/my-temp-dir"
#   register_cleanup "/tmp/my-temp-file"
#
# The cleanup handler will automatically remove registered items if the
# build is interrupted or exits with an error.
register_cleanup() {
    local item="$1"
    if [ -z "$item" ]; then
        log_warning "register_cleanup called with empty argument"
        return 1
    fi

    _FEATURE_CLEANUP_ITEMS+=("$item")
    log_message "Registered for cleanup: $item" >&2
}

# unregister_cleanup - Remove an item from cleanup list
#
# Usage:
#   unregister_cleanup "/tmp/my-temp-dir"
#
# Call this when you've successfully processed a temporary item and
# no longer need it cleaned up on interruption.
unregister_cleanup() {
    local item="$1"
    local new_array=()
    local tracked_item

    for tracked_item in "${_FEATURE_CLEANUP_ITEMS[@]}"; do
        if [ "$tracked_item" != "$item" ]; then
            new_array+=("$tracked_item")
        fi
    done

    _FEATURE_CLEANUP_ITEMS=("${new_array[@]}")
    log_message "Unregistered from cleanup: $item" >&2
}

# Set up trap handlers for cleanup
# These fire on:
# - EXIT: Normal script exit (with any exit code)
# - INT: Interrupt signal (Ctrl+C)
# - TERM: Termination signal
trap cleanup_on_interrupt EXIT INT TERM
