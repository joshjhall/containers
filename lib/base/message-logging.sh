#!/bin/bash
# Simple message logging functions
#
# Provides level-aware message logging: info, debug, error, and warning.
# Each function respects LOG_LEVEL, scrubs secrets, and writes to the
# current feature log file when available.
#
# This is a sub-module of logging.sh — source logging.sh instead of this file
# directly to get the full logging system.
#
# Functions provided:
#   log_message  - Log a simple message (INFO level)
#   log_info     - Alias for log_message with clearer intent
#   log_debug    - Log a debug message (DEBUG level only)
#   log_error    - Log an error message and increment ERROR_COUNT
#   log_warning  - Log a warning message (WARN level) and increment WARNING_COUNT

# Prevent multiple sourcing
if [ -n "${_MESSAGE_LOGGING_LOADED:-}" ]; then
    return 0
fi
_MESSAGE_LOGGING_LOADED=1

# ============================================================================
# log_message - Log a simple message (INFO level)
#
# Arguments:
#   $1 - Message to log
#
# Example:
#   log_message "Creating cache directories..."
# ============================================================================
log_message() {
    # Respect LOG_LEVEL
    if ! _should_log $LOG_LEVEL_INFO; then
        return 0
    fi

    local message="$1"
    # Scrub secrets from message before logging
    if command -v scrub_secrets >/dev/null 2>&1; then
        message=$(scrub_secrets "$message")
    fi

    # Handle case where logging is not yet initialized
    if [ -n "$CURRENT_LOG_FILE" ]; then
        {
            echo "[$(date '+%H:%M:%S')] $message"
        } | command tee -a "$CURRENT_LOG_FILE"
    else
        # Logging not initialized yet, just print to stdout
        echo "[$(date '+%H:%M:%S')] $message"
    fi
}

# ============================================================================
# log_info - Log an informational message (INFO level)
#
# Explicit INFO level logging. Same as log_message but clearer intent.
#
# Arguments:
#   $1 - Message to log
#
# Example:
#   log_info "Starting installation..."
# ============================================================================
log_info() {
    log_message "$1"
}

# ============================================================================
# log_debug - Log a debug message (DEBUG level)
#
# Only shown when LOG_LEVEL=DEBUG. Use for detailed troubleshooting info.
#
# Arguments:
#   $1 - Message to log
#
# Example:
#   log_debug "Checking path: $path"
# ============================================================================
log_debug() {
    # Respect LOG_LEVEL
    if ! _should_log $LOG_LEVEL_DEBUG; then
        return 0
    fi

    local message="$1"
    # Scrub secrets from message before logging
    if command -v scrub_secrets >/dev/null 2>&1; then
        message=$(scrub_secrets "$message")
    fi

    # Handle case where logging is not yet initialized
    if [ -n "$CURRENT_LOG_FILE" ]; then
        {
            echo "[$(date '+%H:%M:%S')] DEBUG: $message"
        } | command tee -a "$CURRENT_LOG_FILE"
    else
        # Logging not initialized yet, just print to stdout
        echo "[$(date '+%H:%M:%S')] DEBUG: $message"
    fi
}

# ============================================================================
# log_error - Log an error message
#
# Arguments:
#   $1 - Error message
#
# Example:
#   log_error "Failed to download package"
# ============================================================================
log_error() {
    local message="$1"
    # Scrub secrets from message before logging
    if command -v scrub_secrets >/dev/null 2>&1; then
        message=$(scrub_secrets "$message")
    fi

    # Handle case where logging is not yet initialized
    if [ -n "$CURRENT_LOG_FILE" ] && [ -n "$CURRENT_ERROR_FILE" ]; then
        {
            echo "[$(date '+%H:%M:%S')] ERROR: $message"
        } | command tee -a "$CURRENT_LOG_FILE" >>"$CURRENT_ERROR_FILE"
    else
        # Logging not initialized yet, just print to stderr
        echo "[$(date '+%H:%M:%S')] ERROR: $message" >&2
    fi

    ERROR_COUNT=$((ERROR_COUNT + 1))

    # Log to JSON if enabled
    if [ "${ENABLE_JSON_LOGGING:-false}" = "true" ] && command -v json_log_error >/dev/null 2>&1; then
        json_log_error "$message"
    fi
}

# ============================================================================
# log_warning - Log a warning message (WARN level)
#
# Arguments:
#   $1 - Warning message
#
# Example:
#   log_warning "Package version might be outdated"
# ============================================================================
log_warning() {
    # Respect LOG_LEVEL
    if ! _should_log $LOG_LEVEL_WARN; then
        return 0
    fi

    local message="$1"
    # Scrub secrets from message before logging
    if command -v scrub_secrets >/dev/null 2>&1; then
        message=$(scrub_secrets "$message")
    fi

    # Handle case where logging is not yet initialized
    if [ -n "$CURRENT_LOG_FILE" ] && [ -n "$CURRENT_ERROR_FILE" ]; then
        {
            echo "[$(date '+%H:%M:%S')] WARNING: $message"
        } | command tee -a "$CURRENT_LOG_FILE" >>"$CURRENT_ERROR_FILE"
    else
        # Logging not initialized yet, just print to stderr
        echo "[$(date '+%H:%M:%S')] WARNING: $message" >&2
    fi

    WARNING_COUNT=$((WARNING_COUNT + 1))

    # Log to JSON if enabled
    if [ "${ENABLE_JSON_LOGGING:-false}" = "true" ] && command -v json_log_warning >/dev/null 2>&1; then
        json_log_warning "$message"
    fi
}
