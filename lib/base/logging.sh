#!/bin/bash
# Generic logging functions for feature installations
#
# This script provides consistent logging functionality across all feature
# installations, capturing output, errors, and generating summaries.
#
# Usage:
#   Source this file in your feature script:
#     source /tmp/build-scripts/base/logging.sh
#
#   Then use:
#     log_feature_start "Python" "3.13.5"
#     log_command "Installing Python dependencies" apt-get install -y ...
#     log_feature_end
#

set -euo pipefail

# Global variables for logging
export BUILD_LOG_DIR="/var/log/container-build"
export CURRENT_FEATURE=""
export CURRENT_LOG_FILE=""
export CURRENT_ERROR_FILE=""
export CURRENT_SUMMARY_FILE=""
export FEATURE_START_TIME=""
export COMMAND_COUNT=0
export ERROR_COUNT=0
export WARNING_COUNT=0

# Create main log directory
mkdir -p "$BUILD_LOG_DIR"

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
    safe_name=$(echo "$feature_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd '[:alnum:]-')
    
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
    } | tee "$CURRENT_LOG_FILE"
    
    # Clear error file
    true > "$CURRENT_ERROR_FILE"
    
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
    
    # Log command start
    {
        echo ""
        echo "[$(date '+%H:%M:%S')] COMMAND #$COMMAND_COUNT: $description"
        echo "Executing: $*"
        echo "--------------------------------------------------------------------------------"
    } | tee -a "$CURRENT_LOG_FILE"
    
    # Execute command and capture output
    local start_time
    start_time=$(date +%s)
    local exit_code=0
    
    # Run command with output capture
    if "$@" 2>&1 | tee -a "$CURRENT_LOG_FILE"; then
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
    } | tee -a "$CURRENT_LOG_FILE"
    
    # Extract any errors or warnings from the last command output
    if [ -f "$CURRENT_LOG_FILE" ]; then
        # Get lines since the last command marker
        tail -n +$(($(grep -n "^Executing: " "$CURRENT_LOG_FILE" | tail -1 | cut -d: -f1) + 1)) "$CURRENT_LOG_FILE" | \
        grep -E "(ERROR|Error|error|FAILED|Failed|failed|FATAL|Fatal|fatal)" >> "$CURRENT_ERROR_FILE" 2>/dev/null || true
        
        local new_errors
        new_errors=$(tail -n +$(($(grep -n "^Executing: " "$CURRENT_LOG_FILE" | tail -1 | cut -d: -f1) + 1)) "$CURRENT_LOG_FILE" | \
        grep -cE "(ERROR|Error|error|FAILED|Failed|failed|FATAL|Fatal|fatal)" 2>/dev/null || echo 0)
        new_errors=$(echo "$new_errors" | tr -d '[:space:]')
        ERROR_COUNT=$((ERROR_COUNT + ${new_errors:-0}))
        
        tail -n +$(($(grep -n "^Executing: " "$CURRENT_LOG_FILE" | tail -1 | cut -d: -f1) + 1)) "$CURRENT_LOG_FILE" | \
        grep -E "(WARNING|Warning|warning|WARN|Warn|warn)" >> "$CURRENT_ERROR_FILE" 2>/dev/null || true
        
        local new_warnings
        new_warnings=$(tail -n +$(($(grep -n "^Executing: " "$CURRENT_LOG_FILE" | tail -1 | cut -d: -f1) + 1)) "$CURRENT_LOG_FILE" | \
        grep -cE "(WARNING|Warning|warning|WARN|Warn|warn)" 2>/dev/null || echo 0)
        new_warnings=$(echo "$new_warnings" | tr -d '[:space:]')
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
            head -10 "$CURRENT_ERROR_FILE"
            echo ""
            echo "Full error log: $CURRENT_ERROR_FILE"
        else
            echo "No errors or warnings detected!"
        fi
        
        echo ""
        echo "End Time: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "================================================================================"
    } | tee "$CURRENT_SUMMARY_FILE"
    
    # Append summary to main log
    echo "" >> "$CURRENT_LOG_FILE"
    cat "$CURRENT_SUMMARY_FILE" >> "$CURRENT_LOG_FILE"
    
    # Create a master summary file
    {
        echo "$CURRENT_FEATURE: $ERROR_COUNT errors, $WARNING_COUNT warnings (${total_duration}s)"
    } >> "$BUILD_LOG_DIR/master-summary.log"
    
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

# ============================================================================
# log_message - Log a simple message
# 
# Arguments:
#   $1 - Message to log
#
# Example:
#   log_message "Creating cache directories..."
# ============================================================================
log_message() {
    local message="$1"
    
    {
        echo "[$(date '+%H:%M:%S')] $message"
    } | tee -a "$CURRENT_LOG_FILE"
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
    
    {
        echo "[$(date '+%H:%M:%S')] ERROR: $message"
    } | tee -a "$CURRENT_LOG_FILE" >> "$CURRENT_ERROR_FILE"
    
    ERROR_COUNT=$((ERROR_COUNT + 1))
}

# ============================================================================
# log_warning - Log a warning message
# 
# Arguments:
#   $1 - Warning message
#
# Example:
#   log_warning "Package version might be outdated"
# ============================================================================
log_warning() {
    local message="$1"
    
    {
        echo "[$(date '+%H:%M:%S')] WARNING: $message"
    } | tee -a "$CURRENT_LOG_FILE" >> "$CURRENT_ERROR_FILE"
    
    WARNING_COUNT=$((WARNING_COUNT + 1))
}

# Export functions for use in feature scripts
export -f log_feature_start
export -f log_command
export -f log_feature_end
export -f log_message
export -f log_error
export -f log_warning