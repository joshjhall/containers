#!/bin/bash
# JSON logging utilities for structured observability
#
# This script provides JSON-formatted logging that complements the existing
# text-based logging system. It's designed for log aggregation systems like
# Loki, Elasticsearch, or CloudWatch Logs.
#
# Usage:
#   Source this file in logging.sh or feature scripts:
#     source /tmp/build-scripts/base/json-logging.sh
#
#   Enable JSON logging:
#     export ENABLE_JSON_LOGGING=true
#
#   Then use existing logging functions - JSON logs are automatic

# Prevent multiple sourcing
if [ -n "${_JSON_LOGGING_LOADED:-}" ]; then
    return 0
fi
_JSON_LOGGING_LOADED=1

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

# JSON log directory (separate from text logs for easier collection)
export JSON_LOG_DIR="${JSON_LOG_DIR:-${BUILD_LOG_DIR}/json}"

# Create JSON log directory if JSON logging is enabled
if [ "${ENABLE_JSON_LOGGING:-false}" = "true" ]; then
    mkdir -p "$JSON_LOG_DIR" 2>/dev/null || {
        echo "WARNING: Cannot create JSON log directory at $JSON_LOG_DIR" >&2
        ENABLE_JSON_LOGGING=false
    }
fi

# Correlation ID for tracking related logs across build process
# Generate once per build, persist across features
if [ "${ENABLE_JSON_LOGGING:-false}" = "true" ]; then
    if [ -z "${BUILD_CORRELATION_ID:-}" ]; then
        # Generate correlation ID: build-<timestamp>-<random>
        BUILD_CORRELATION_ID="build-$(date +%s)-$(head /dev/urandom | tr -dc a-z0-9 | head -c 6)"
        export BUILD_CORRELATION_ID
    fi
fi

# Current JSON log file (per feature)
export CURRENT_JSON_LOG_FILE=""

# ============================================================================
# json_escape - Escape string for JSON
#
# Arguments:
#   $1 - String to escape
#
# Returns:
#   Escaped string suitable for JSON value
# ============================================================================
json_escape() {
    local string="$1"

    # Scrub secrets before JSON escaping — covers all JSON log paths
    if command -v scrub_secrets >/dev/null 2>&1; then
        string=$(scrub_secrets "$string")
    fi

    # Escape backslashes first
    string="${string//\\/\\\\}"

    # Escape double quotes
    string="${string//\"/\\\"}"

    # Escape control characters
    string="${string//$'\n'/\\n}"
    string="${string//$'\r'/\\r}"
    string="${string//$'\t'/\\t}"

    echo "$string"
}

# ============================================================================
# json_log_init - Initialize JSON logging for a feature
#
# Arguments:
#   $1 - Feature name (e.g., "Python", "Node.js", "Rust")
#   $2 - Version (optional)
#
# This is called automatically by log_feature_start if JSON logging is enabled
# ============================================================================
json_log_init() {
    [ "${ENABLE_JSON_LOGGING:-false}" != "true" ] && return 0

    local feature_name="$1"
    local version="${2:-}"

    # Sanitize feature name for filename
    local safe_name
    safe_name=$(echo "$feature_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd '[:alnum:]-')

    # Set JSON log file path
    CURRENT_JSON_LOG_FILE="$JSON_LOG_DIR/${safe_name}.jsonl"

    # Initialize with feature start event
    json_log_event \
        "INFO" \
        "feature_start" \
        "$(json_escape "Starting installation of $feature_name${version:+ version $version}")" \
        "{\"feature\":\"$(json_escape "$feature_name")\",\"version\":\"$(json_escape "${version:-unknown}")\"}"
}

# ============================================================================
# json_log_event - Log a structured JSON event
#
# Arguments:
#   $1 - Log level (DEBUG, INFO, WARN, ERROR, FATAL)
#   $2 - Event type (feature_start, feature_end, command, error, warning, etc.)
#   $3 - Message
#   $4 - Additional metadata (JSON object, optional)
#
# Example:
#   json_log_event "INFO" "command" "Installing dependencies" '{"command_num":1,"duration_ms":1234}'
# ============================================================================
json_log_event() {
    [ "${ENABLE_JSON_LOGGING:-false}" != "true" ] && return 0
    [ -z "${CURRENT_JSON_LOG_FILE:-}" ] && return 0

    local level="$1"
    local event_type="$2"
    local message="$3"
    local metadata="${4:-{}}"

    # Generate ISO 8601 timestamp with milliseconds
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Build JSON log entry
    local json_entry
    json_entry=$(command cat <<EOF
{"timestamp":"$timestamp","level":"$level","correlation_id":"${BUILD_CORRELATION_ID}","event_type":"$event_type","feature":"${CURRENT_FEATURE:-unknown}","message":"$(json_escape "$message")","metadata":$metadata}
EOF
)

    # Append to JSON log file (JSONL format - one JSON object per line)
    echo "$json_entry" >> "$CURRENT_JSON_LOG_FILE"
}

# ============================================================================
# json_log_command - Log a command execution with metrics
#
# Arguments:
#   $1 - Command description
#   $2 - Command number
#   $3 - Exit code
#   $4 - Duration in seconds
#
# This is called automatically by log_command if JSON logging is enabled
# ============================================================================
json_log_command() {
    [ "${ENABLE_JSON_LOGGING:-false}" != "true" ] && return 0

    local description="$1"
    local command_num="$2"
    local exit_code="$3"
    local duration="$4"

    local level="INFO"
    [ "$exit_code" -ne 0 ] && level="ERROR"

    local metadata
    metadata=$(command cat <<EOF
{"command_num":$command_num,"exit_code":$exit_code,"duration_seconds":$duration,"success":$([ "$exit_code" -eq 0 ] && echo "true" || echo "false")}
EOF
)

    json_log_event "$level" "command" "$(json_escape "$description")" "$metadata"
}

# ============================================================================
# json_log_error - Log an error with context
#
# Arguments:
#   $1 - Error message
#
# This is called automatically by log_error if JSON logging is enabled
# ============================================================================
json_log_error() {
    [ "${ENABLE_JSON_LOGGING:-false}" != "true" ] && return 0

    local message="$1"

    local metadata
    metadata=$(command cat <<EOF
{"error_count":${ERROR_COUNT:-0}}
EOF
)

    json_log_event "ERROR" "error" "$(json_escape "$message")" "$metadata"
}

# ============================================================================
# json_log_warning - Log a warning with context
#
# Arguments:
#   $1 - Warning message
#
# This is called automatically by log_warning if JSON logging is enabled
# ============================================================================
json_log_warning() {
    [ "${ENABLE_JSON_LOGGING:-false}" != "true" ] && return 0

    local message="$1"

    local metadata
    metadata=$(command cat <<EOF
{"warning_count":${WARNING_COUNT:-0}}
EOF
)

    json_log_event "WARN" "warning" "$(json_escape "$message")" "$metadata"
}

# ============================================================================
# json_log_feature_end - Log feature completion with summary metrics
#
# Arguments:
#   $1 - Total duration in seconds
#
# This is called automatically by log_feature_end if JSON logging is enabled
# ============================================================================
json_log_feature_end() {
    [ "${ENABLE_JSON_LOGGING:-false}" != "true" ] && return 0

    local duration="$1"

    local metadata
    metadata=$(command cat <<EOF
{"duration_seconds":$duration,"commands_executed":${COMMAND_COUNT:-0},"errors":${ERROR_COUNT:-0},"warnings":${WARNING_COUNT:-0},"status":"$([ "${ERROR_COUNT:-0}" -eq 0 ] && echo "success" || echo "failed")"}
EOF
)

    json_log_event "INFO" "feature_end" "$(json_escape "Completed installation of ${CURRENT_FEATURE}")" "$metadata"

    # Also log to master JSON summary
    if [ -n "${CURRENT_JSON_LOG_FILE:-}" ]; then
        local summary_file="$JSON_LOG_DIR/build-summary.jsonl"

        # Generate summary entry with correlation ID for aggregation
        local timestamp
        timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")

        local summary_entry
        summary_entry=$(command cat <<EOF
{"timestamp":"$timestamp","correlation_id":"${BUILD_CORRELATION_ID}","feature":"${CURRENT_FEATURE}","duration_seconds":$duration,"commands":${COMMAND_COUNT:-0},"errors":${ERROR_COUNT:-0},"warnings":${WARNING_COUNT:-0},"status":"$([ "${ERROR_COUNT:-0}" -eq 0 ] && echo "success" || echo "failed")"}
EOF
)

        echo "$summary_entry" >> "$summary_file"
    fi
}

# ============================================================================
# json_log_build_metadata - Log build-time metadata (called once at start)
#
# This captures build arguments, platform info, etc. for context
# ============================================================================
json_log_build_metadata() {
    [ "${ENABLE_JSON_LOGGING:-false}" != "true" ] && return 0

    local metadata_file="$JSON_LOG_DIR/build-metadata.json"

    # Collect build metadata
    local base_image="${BASE_IMAGE:-unknown}"
    local project_name="${PROJECT_NAME:-unknown}"
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Write metadata file (single JSON object, not JSONL)
    command cat > "$metadata_file" <<EOF
{
  "correlation_id": "${BUILD_CORRELATION_ID}",
  "timestamp": "$timestamp",
  "base_image": "$base_image",
  "project_name": "$project_name",
  "platform": "$(uname -s 2>/dev/null || echo unknown)",
  "architecture": "$(uname -m 2>/dev/null || echo unknown)",
  "build_args": {
    "include_python_dev": "${INCLUDE_PYTHON_DEV:-false}",
    "include_node_dev": "${INCLUDE_NODE_DEV:-false}",
    "include_rust_dev": "${INCLUDE_RUST_DEV:-false}",
    "include_golang_dev": "${INCLUDE_GOLANG_DEV:-false}",
    "include_java_dev": "${INCLUDE_JAVA_DEV:-false}",
    "include_r_dev": "${INCLUDE_R_DEV:-false}",
    "include_ruby_dev": "${INCLUDE_RUBY_DEV:-false}",
    "include_mojo_dev": "${INCLUDE_MOJO_DEV:-false}",
    "include_docker": "${INCLUDE_DOCKER:-false}",
    "include_kubernetes": "${INCLUDE_KUBERNETES:-false}",
    "include_terraform": "${INCLUDE_TERRAFORM:-false}",
    "include_dev_tools": "${INCLUDE_DEV_TOOLS:-false}"
  }
}
EOF
}

# Export functions for use in other scripts
export -f json_escape
export -f json_log_init
export -f json_log_event
export -f json_log_command
export -f json_log_error
export -f json_log_warning
export -f json_log_feature_end
export -f json_log_build_metadata
