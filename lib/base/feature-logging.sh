#!/bin/bash
# Feature lifecycle logging functions
#
# Provides feature installation logging: start/end lifecycle, command execution
# with output capture, error/warning counting, and JSON logging integration.
#
# This is a sub-module of logging.sh — source logging.sh instead of this file
# directly to get the full logging system.
#
# Functions provided:
#   log_feature_start  - Initialize logging for a feature installation
#   log_command        - Execute and log a command with output capture
#   log_feature_end    - Finalize logging and generate summary
#
# Internal helpers:
#   _get_last_command_start_line  - Find last command marker in log
#   _count_patterns_since         - Count regex matches after a line

# Prevent multiple sourcing
if [ -n "${_FEATURE_LOGGING_LOADED:-}" ]; then
    return 0
fi
_FEATURE_LOGGING_LOADED=1

# Get line number after last "Executing:" marker in a log file
_get_last_command_start_line() {
    local log_file="$1"
    local marker_line
    marker_line=$(command grep -n "^Executing: " "$log_file" | command tail -1 | command cut -d: -f1)
    echo $((marker_line + 1))
}

# Count pattern matches in log output since a given line
_count_patterns_since() {
    local log_file="$1"
    local start_line="$2"
    local pattern="$3"
    command tail -n +"$start_line" "$log_file" | command grep -cE "$pattern" 2>/dev/null || echo 0
}

# Global variables for feature logging
export CURRENT_FEATURE=""
export CURRENT_LOG_FILE=""
export CURRENT_ERROR_FILE=""
export CURRENT_SUMMARY_FILE=""
export FEATURE_START_TIME=""
export COMMAND_COUNT=0
export ERROR_COUNT=0
export WARNING_COUNT=0

# ============================================================================
# log_feature_start - Initialize logging for a feature installation
#
# Arguments:
#   $1 - Feature name (e.g., "Python", "Node.js", "Rust")
#   $2 - Version (optional, e.g., "3.13.5")
#
# Example:
#   log_feature_start "Python" "3.13.5"
# ============================================================================
log_feature_start() {
    local feature_name="$1"
    local version="${2:-}"

    # Sanitize feature name for filename
    local safe_name
    safe_name=$(echo "$feature_name" | command tr '[:upper:]' '[:lower:]' | command tr ' ' '-' | command tr -cd '[:alnum:]-')

    # Set up logging paths
    CURRENT_FEATURE="$feature_name"
    CURRENT_LOG_FILE="$BUILD_LOG_DIR/${safe_name}-install.log"
    CURRENT_ERROR_FILE="$BUILD_LOG_DIR/${safe_name}-errors.log"
    CURRENT_SUMMARY_FILE="$BUILD_LOG_DIR/${safe_name}-summary.log"
    FEATURE_START_TIME=$(date +%s)
    COMMAND_COUNT=0
    ERROR_COUNT=0
    WARNING_COUNT=0

    # Initialize log files
    {
        echo "================================================================================"
        echo "Feature Installation Log: $feature_name"
        [ -n "$version" ] && echo "Version: $version"
        echo "Start Time: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "================================================================================"
        echo ""
    } | command tee "$CURRENT_LOG_FILE"

    # Clear error file
    true >"$CURRENT_ERROR_FILE"

    # Initialize JSON logging if enabled
    if [ "${ENABLE_JSON_LOGGING:-false}" = "true" ] && command -v json_log_init >/dev/null 2>&1; then
        json_log_init "$feature_name" "$version"
    fi

    # Show on console
    echo "=== Installing $feature_name${version:+ version $version} ==="
}

# ============================================================================
# log_command - Execute and log a command
#
# Arguments:
#   $1 - Description of what the command does
#   $@ - The command to execute
#
# Example:
#   log_command "Installing system dependencies" apt-get install -y build-essential
# ============================================================================
log_command() {
    local description="$1"
    shift

    COMMAND_COUNT=$((COMMAND_COUNT + 1))

    # Scrub command text for logging (the command itself may contain secrets)
    local logged_cmd="$*"
    if command -v scrub_secrets >/dev/null 2>&1; then
        logged_cmd=$(scrub_secrets "$logged_cmd")
    fi

    # Log command start
    {
        echo ""
        echo "[$(date '+%H:%M:%S')] COMMAND #$COMMAND_COUNT: $description"
        echo "Executing: $logged_cmd"
        echo "--------------------------------------------------------------------------------"
    } | command tee -a "$CURRENT_LOG_FILE"

    # Execute command and capture output
    local start_time
    start_time=$(date +%s)
    local exit_code=0

    # Run command with output capture, scrubbing secrets from output
    if command -v scrub_secrets >/dev/null 2>&1; then
        if "$@" 2>&1 | scrub_secrets | command tee -a "$CURRENT_LOG_FILE"; then
            exit_code=0
        else
            exit_code=$?
        fi
    elif "$@" 2>&1 | command tee -a "$CURRENT_LOG_FILE"; then
        exit_code=0
    else
        exit_code=$?
    fi

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    # Log command result
    {
        echo "--------------------------------------------------------------------------------"
        echo "Exit code: $exit_code (Duration: ${duration}s)"
    } | command tee -a "$CURRENT_LOG_FILE"

    # Log to JSON if enabled
    if [ "${ENABLE_JSON_LOGGING:-false}" = "true" ] && command -v json_log_command >/dev/null 2>&1; then
        json_log_command "$description" "$COMMAND_COUNT" "$exit_code" "$duration"
    fi

    # Extract any errors or warnings from the last command output
    if [ -f "$CURRENT_LOG_FILE" ]; then
        local start_line
        start_line=$(_get_last_command_start_line "$CURRENT_LOG_FILE")

        local error_pattern="(ERROR|Error|error|FAILED|Failed|failed|FATAL|Fatal|fatal)"
        local warn_pattern="(WARNING|Warning|warning|WARN|Warn|warn)"

        # Append matching lines to error file
        command tail -n +"$start_line" "$CURRENT_LOG_FILE" | command grep -E "$error_pattern" >>"$CURRENT_ERROR_FILE" 2>/dev/null || true
        command tail -n +"$start_line" "$CURRENT_LOG_FILE" | command grep -E "$warn_pattern" >>"$CURRENT_ERROR_FILE" 2>/dev/null || true

        # Count new errors and warnings
        local new_errors
        new_errors=$(_count_patterns_since "$CURRENT_LOG_FILE" "$start_line" "$error_pattern")
        new_errors=$(echo "$new_errors" | command tr -d '[:space:]')
        ERROR_COUNT=$((ERROR_COUNT + ${new_errors:-0}))

        local new_warnings
        new_warnings=$(_count_patterns_since "$CURRENT_LOG_FILE" "$start_line" "$warn_pattern")
        new_warnings=$(echo "$new_warnings" | command tr -d '[:space:]')
        WARNING_COUNT=$((WARNING_COUNT + ${new_warnings:-0}))
    fi

    # Show status on console
    if [ $exit_code -eq 0 ]; then
        echo "✓ $description completed successfully"
    else
        echo "✗ $description failed with exit code $exit_code"
    fi

    return $exit_code
}

# ============================================================================
# log_feature_end - Finalize logging and generate summary
#
# Arguments:
#   None
#
# Example:
#   log_feature_end
# ============================================================================
log_feature_end() {
    local end_time
    end_time=$(date +%s)
    local total_duration=$((end_time - FEATURE_START_TIME))

    # Generate summary
    {
        echo "================================================================================"
        echo "Installation Summary: $CURRENT_FEATURE"
        echo "================================================================================"
        echo ""
        echo "Total Duration: ${total_duration} seconds"
        echo "Commands Executed: $COMMAND_COUNT"
        echo "Errors Found: $ERROR_COUNT"
        echo "Warnings Found: $WARNING_COUNT"
        echo ""

        if [ -s "$CURRENT_ERROR_FILE" ]; then
            echo "--- First 10 Errors/Warnings ---"
            command head -10 "$CURRENT_ERROR_FILE"
            echo ""
            echo "Full error log: $CURRENT_ERROR_FILE"
        else
            echo "No errors or warnings detected!"
        fi

        echo ""
        echo "End Time: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "================================================================================"
    } | command tee "$CURRENT_SUMMARY_FILE"

    # Append summary to main log
    echo "" >>"$CURRENT_LOG_FILE"
    command cat "$CURRENT_SUMMARY_FILE" >>"$CURRENT_LOG_FILE"

    # Create a master summary file
    {
        echo "$CURRENT_FEATURE: $ERROR_COUNT errors, $WARNING_COUNT warnings (${total_duration}s)"
    } >>"$BUILD_LOG_DIR/master-summary.log"

    # Log feature completion to JSON if enabled
    if [ "${ENABLE_JSON_LOGGING:-false}" = "true" ] && command -v json_log_feature_end >/dev/null 2>&1; then
        json_log_feature_end "$total_duration"
    fi

    # Show summary on console
    echo ""
    echo "=== $CURRENT_FEATURE installation complete ==="
    echo "Errors: $ERROR_COUNT, Warnings: $WARNING_COUNT"
    echo "Full log: $CURRENT_LOG_FILE"

    # Reset variables
    CURRENT_FEATURE=""
    CURRENT_LOG_FILE=""
    CURRENT_ERROR_FILE=""
    CURRENT_SUMMARY_FILE=""
}
