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
# Allow BUILD_LOG_DIR to be overridden (e.g., for tests)
if [ -z "${BUILD_LOG_DIR:-}" ]; then
    # Try /var/log/container-build first (for root or proper permissions)
    if mkdir -p /var/log/container-build 2>/dev/null; then
        export BUILD_LOG_DIR="/var/log/container-build"
    else
        # Fallback to /tmp for non-root or restricted environments
        export BUILD_LOG_DIR="/tmp/container-build"
        mkdir -p "$BUILD_LOG_DIR" 2>/dev/null || {
            echo "ERROR: Cannot create log directory at /var/log/container-build or /tmp/container-build" >&2
            exit 1
        }
    fi
else
    # BUILD_LOG_DIR was explicitly set, use it and ensure it exists
    mkdir -p "$BUILD_LOG_DIR" 2>/dev/null || {
        echo "ERROR: Cannot create log directory at $BUILD_LOG_DIR" >&2
        exit 1
    }
fi

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

    # Handle case where logging is not yet initialized
    if [ -n "$CURRENT_LOG_FILE" ]; then
        {
            echo "[$(date '+%H:%M:%S')] $message"
        } | tee -a "$CURRENT_LOG_FILE"
    else
        # Logging not initialized yet, just print to stdout
        echo "[$(date '+%H:%M:%S')] $message"
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

    # Handle case where logging is not yet initialized
    if [ -n "$CURRENT_LOG_FILE" ] && [ -n "$CURRENT_ERROR_FILE" ]; then
        {
            echo "[$(date '+%H:%M:%S')] ERROR: $message"
        } | tee -a "$CURRENT_LOG_FILE" >> "$CURRENT_ERROR_FILE"
    else
        # Logging not initialized yet, just print to stderr
        echo "[$(date '+%H:%M:%S')] ERROR: $message" >&2
    fi

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

    # Handle case where logging is not yet initialized
    if [ -n "$CURRENT_LOG_FILE" ] && [ -n "$CURRENT_ERROR_FILE" ]; then
        {
            echo "[$(date '+%H:%M:%S')] WARNING: $message"
        } | tee -a "$CURRENT_LOG_FILE" >> "$CURRENT_ERROR_FILE"
    else
        # Logging not initialized yet, just print to stderr
        echo "[$(date '+%H:%M:%S')] WARNING: $message" >&2
    fi

    WARNING_COUNT=$((WARNING_COUNT + 1))
}

# ============================================================================
# safe_eval - Safely evaluate command output with validation
#
# This function mitigates command injection risks when using eval with tool
# initialization commands (e.g., rbenv init, direnv hook, zoxide init).
#
# Arguments:
#   $1 - Description of command (e.g., "zoxide init bash")
#   $@ - The command to execute
#
# Returns:
#   0 - Command executed successfully
#   1 - Command failed or suspicious output detected
#
# Example:
#   safe_eval "zoxide init bash" zoxide init bash
#   safe_eval "direnv hook" direnv hook bash
# ============================================================================
safe_eval() {
    local description="$1"
    shift
    local output
    local exit_code=0

    # Try to execute the command and capture output
    if ! output=$("$@" 2>/dev/null); then
        log_warning "Failed to initialize $description"
        return 1
    fi

    # Check for suspicious patterns that could indicate compromise
    # These patterns catch common command injection attempts
    # Use 'command grep' to bypass any aliases (e.g., grep='rg' from dev-tools)
    if echo "$output" | command grep -qE '(rm -rf|curl.*bash|wget.*bash|;\s*rm|\$\(.*rm)'; then
        log_error "SECURITY: Suspicious output from $description, skipping initialization"
        log_error "This may indicate a compromised tool or supply chain attack"
        return 1
    fi

    # Check for other dangerous command patterns
    if echo "$output" | command grep -qE '(exec\s+[^$]|/bin/sh.*-c|bash.*-c.*http)'; then
        log_error "SECURITY: Potentially dangerous commands in $description output"
        return 1
    fi

    # Output looks safe, evaluate it
    eval "$output" || exit_code=$?

    if [ $exit_code -ne 0 ]; then
        log_warning "$description initialization completed with non-zero exit code: $exit_code"
        return $exit_code
    fi

    return 0
}

# Export functions for use in feature scripts
# ============================================================================
# log_feature_summary - Output user-friendly configuration summary
#
# This function should be called BEFORE log_feature_end() to provide users
# with actionable information about what was installed and configured.
#
# Arguments:
#   --feature <name>       Feature name (e.g., "Python")
#   --version <version>    Version installed
#   --tools <tool1,tool2>  Comma-separated list of tools
#   --paths <path1,path2>  Comma-separated list of important paths
#   --env <VAR1,VAR2>      Comma-separated list of environment variables
#   --commands <cmd1,cmd2> Comma-separated list of available commands
#   --next-steps <text>    Next steps for the user
#
# Example:
#   log_feature_summary \
#       --feature "Python" \
#       --version "${PYTHON_VERSION}" \
#       --tools "pip,poetry,pipx" \
#       --paths "${PIP_CACHE_DIR},${POETRY_CACHE_DIR}" \
#       --env "PIP_CACHE_DIR,POETRY_CACHE_DIR,PIPX_HOME" \
#       --commands "python3,pip,poetry" \
#       --next-steps "Run 'test-python' to verify installation"
# ============================================================================
log_feature_summary() {
    local feature="" version="" tools="" paths="" env_vars="" commands="" next_steps=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --feature)
                feature="$2"
                shift 2
                ;;
            --version)
                version="$2"
                shift 2
                ;;
            --tools)
                tools="$2"
                shift 2
                ;;
            --paths)
                paths="$2"
                shift 2
                ;;
            --env)
                env_vars="$2"
                shift 2
                ;;
            --commands)
                commands="$2"
                shift 2
                ;;
            --next-steps)
                next_steps="$2"
                shift 2
                ;;
            *)
                log_warning "Unknown argument to log_feature_summary: $1"
                shift
                ;;
        esac
    done

    # Generate summary output
    {
        echo ""
        echo "================================================================================"
        echo "${feature} Configuration Summary"
        echo "================================================================================"
        echo ""

        if [ -n "$version" ]; then
            echo "Version:      $version"
        fi

        if [ -n "$tools" ]; then
            echo "Tools:        ${tools//,/, }"
        fi

        if [ -n "$commands" ]; then
            echo "Commands:     ${commands//,/, }"
        fi

        if [ -n "$paths" ]; then
            echo ""
            echo "Paths:"
            IFS=',' read -ra PATH_ARRAY <<< "$paths"
            for path in "${PATH_ARRAY[@]}"; do
                echo "  - $path"
            done
        fi

        if [ -n "$env_vars" ]; then
            echo ""
            echo "Environment Variables:"
            IFS=',' read -ra ENV_ARRAY <<< "$env_vars"
            for var in "${ENV_ARRAY[@]}"; do
                # Try to get the value
                value="${!var:-<not set>}"
                echo "  - $var=$value"
            done
        fi

        if [ -n "$next_steps" ]; then
            echo ""
            echo "Next Steps:"
            echo "  $next_steps"
        fi

        echo ""
        echo "Run 'check-build-logs.sh $(echo "$feature" | tr '[:upper:]' '[:lower:]')' to review installation logs"
        echo "================================================================================"
        echo ""
    } | tee -a "$CURRENT_LOG_FILE"
}

export -f log_feature_start
export -f log_command
export -f log_feature_end
export -f log_feature_summary
export -f log_message
export -f log_error
export -f log_warning
export -f safe_eval