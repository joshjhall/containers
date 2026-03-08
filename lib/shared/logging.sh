#!/bin/bash
# Shared lightweight logging functions for runtime use
#
# This module provides the core logging functions needed by both build-time
# and runtime scripts. Build-time logging (lib/base/logging.sh) sources this
# and extends it with feature logging, file-based logging, counters, JSON
# output, and secret scrubbing.
#
# Runtime scripts should source this (via /opt/container-runtime/shared/)
# instead of the full build-time logging.sh.
#
# Functions provided:
#   _get_log_level_num  - Convert LOG_LEVEL string to numeric
#   _should_log         - Check if a message at given level should be logged
#   log_message         - Log an informational message (INFO level)
#   log_info            - Alias for log_message
#   log_debug           - Log a debug message (DEBUG level)
#   log_error           - Log an error message (always shown)
#   log_warning         - Log a warning message (WARN level)

# Prevent multiple sourcing
if [ -n "${_SHARED_LOGGING_LOADED:-}" ]; then
    return 0
fi
_SHARED_LOGGING_LOADED=1

# ============================================================================
# Log Level Configuration
# ============================================================================
# Levels: ERROR (0), WARN (1), INFO (2), DEBUG (3)
# Default: INFO - shows errors, warnings, and informational messages

# Numeric log levels
export LOG_LEVEL_ERROR=0
export LOG_LEVEL_WARN=1
export LOG_LEVEL_INFO=2
export LOG_LEVEL_DEBUG=3

# Convert string log level to numeric
_get_log_level_num() {
    case "${LOG_LEVEL:-INFO}" in
        ERROR|error|0) echo $LOG_LEVEL_ERROR ;;
        WARN|warn|WARNING|warning|1) echo $LOG_LEVEL_WARN ;;
        INFO|info|2) echo $LOG_LEVEL_INFO ;;
        DEBUG|debug|3) echo $LOG_LEVEL_DEBUG ;;
        *) echo $LOG_LEVEL_INFO ;; # Default for invalid values
    esac
}

# Check if a message at given level should be logged
_should_log() {
    local level=$1
    local current
    current=$(_get_log_level_num)
    [ "$level" -le "$current" ]
}

# ============================================================================
# log_message - Log a simple message (INFO level)
# ============================================================================
log_message() {
    if ! _should_log $LOG_LEVEL_INFO; then
        return 0
    fi
    echo "[$(date '+%H:%M:%S')] $1"
}

# ============================================================================
# log_info - Alias for log_message (INFO level)
# ============================================================================
log_info() {
    log_message "$1"
}

# ============================================================================
# log_debug - Log a debug message (DEBUG level)
# ============================================================================
log_debug() {
    if ! _should_log $LOG_LEVEL_DEBUG; then
        return 0
    fi
    echo "[$(date '+%H:%M:%S')] DEBUG: $1"
}

# ============================================================================
# log_error - Log an error message (always shown)
# ============================================================================
log_error() {
    echo "[$(date '+%H:%M:%S')] ERROR: $1" >&2
}

# ============================================================================
# log_warning - Log a warning message (WARN level)
# ============================================================================
log_warning() {
    if ! _should_log $LOG_LEVEL_WARN; then
        return 0
    fi
    echo "[$(date '+%H:%M:%S')] WARNING: $1" >&2
}

# Export functions
export -f _get_log_level_num
export -f _should_log
export -f log_message
export -f log_info
export -f log_debug
export -f log_error
export -f log_warning
