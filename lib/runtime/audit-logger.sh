#!/usr/bin/env bash
# Audit Logger - Structured security event logging
# Version: 1.0.0
#
# Description:
#   Provides functions for logging security-relevant events in structured JSON
#   format. Integrates with log shippers (Fluentd, CloudWatch, Loki) and supports
#   compliance retention requirements.
#
# Usage:
#   source /opt/container-runtime/audit-logger.sh
#   audit_log "authentication" "success" "User login" '{"user":"admin","ip":"10.0.0.1"}'
#
# Environment Variables:
#   ENABLE_AUDIT_LOGGING  - Enable/disable audit logging (default: true)
#   AUDIT_LOG_FILE        - Path to audit log file (default: /var/log/audit/container-audit.log)
#   AUDIT_LOG_FORMAT      - Output format: json, cef, syslog (default: json)
#   AUDIT_LOG_LEVEL       - Minimum level: debug, info, warn, error, critical (default: info)
#   AUDIT_INCLUDE_PID     - Include process ID (default: true)
#   AUDIT_INCLUDE_HOST    - Include hostname (default: true)
#   AUDIT_STDOUT_COPY     - Also output to stdout (default: false)
#
# Compliance Coverage:
#   - SOC 2 CC7.2: Security event monitoring
#   - ISO 27001 A.12.4: Logging and monitoring
#   - HIPAA 164.312(b): Audit controls
#   - PCI DSS 10.2: Audit trail events
#   - GDPR Art. 30: Records of processing activities
#   - FedRAMP AU-2: Audit events
#   - NIST 800-53 AU-2: Event logging
#
# Log Retention Requirements by Framework:
#   - SOC 2:    12 months minimum
#   - HIPAA:    6 years
#   - PCI DSS:  1 year (3 months immediately available)
#   - GDPR:     As long as necessary for processing
#   - FedRAMP:  3 years
#
# shellcheck disable=SC2034

set -eo pipefail

# ============================================================================
# Configuration
# ============================================================================

ENABLE_AUDIT_LOGGING="${ENABLE_AUDIT_LOGGING:-true}"
AUDIT_LOG_FILE="${AUDIT_LOG_FILE:-/var/log/audit/container-audit.log}"
AUDIT_LOG_FORMAT="${AUDIT_LOG_FORMAT:-json}"
AUDIT_LOG_LEVEL="${AUDIT_LOG_LEVEL:-info}"
AUDIT_INCLUDE_PID="${AUDIT_INCLUDE_PID:-true}"
AUDIT_INCLUDE_HOST="${AUDIT_INCLUDE_HOST:-true}"
AUDIT_STDOUT_COPY="${AUDIT_STDOUT_COPY:-false}"

# Log level numeric values
declare -A LOG_LEVELS=(
    ["debug"]=0
    ["info"]=1
    ["warn"]=2
    ["error"]=3
    ["critical"]=4
)

# Event categories for compliance mapping
declare -A EVENT_CATEGORIES=(
    ["authentication"]="AUTH"
    ["authorization"]="AUTHZ"
    ["data_access"]="DATA"
    ["configuration"]="CONFIG"
    ["system"]="SYS"
    ["network"]="NET"
    ["file"]="FILE"
    ["process"]="PROC"
    ["security"]="SEC"
    ["compliance"]="COMP"
)

# ============================================================================
# Initialization
# ============================================================================

# Initialize audit logging system
audit_init() {
    if [ "$ENABLE_AUDIT_LOGGING" != "true" ]; then
        return 0
    fi

    # Create audit log directory
    local log_dir
    log_dir=$(dirname "$AUDIT_LOG_FILE")
    if [ ! -d "$log_dir" ]; then
        mkdir -p "$log_dir"
        chmod 750 "$log_dir"
    fi

    # Create log file with secure permissions
    if [ ! -f "$AUDIT_LOG_FILE" ]; then
        touch "$AUDIT_LOG_FILE"
        chmod 640 "$AUDIT_LOG_FILE"
    fi

    # Log initialization event
    audit_log "system" "info" "Audit logging initialized" "{\"version\":\"1.0.0\",\"format\":\"$AUDIT_LOG_FORMAT\"}"
}

# ============================================================================
# JSON Escaping Helper
# ============================================================================

# Escape a string for safe inclusion in a JSON value.
# Handles: backslash, double-quote, tab, newline, carriage return.
_json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/\n/\\n/g; s/\r/\\r/g'
}

# ============================================================================
# Core Logging Functions
# ============================================================================

# Main audit logging function
# Arguments:
#   $1 - Event category (authentication, authorization, data_access, etc.)
#   $2 - Severity level (debug, info, warn, error, critical)
#   $3 - Event message
#   $4 - Additional JSON data (optional)
audit_log() {
    if [ "$ENABLE_AUDIT_LOGGING" != "true" ]; then
        return 0
    fi

    local category="${1:-system}"
    local level="${2:-info}"
    local message="${3:-No message}"
    local extra_data="${4:-{}}"

    # Check log level threshold
    local level_num="${LOG_LEVELS[$level]:-1}"
    local threshold_num="${LOG_LEVELS[$AUDIT_LOG_LEVEL]:-1}"
    if [ "$level_num" -lt "$threshold_num" ]; then
        return 0
    fi

    # Generate timestamp (ISO 8601)
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")

    # Generate unique event ID
    local event_id
    event_id=$(command cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$(date +%s)-$$-$RANDOM")

    # Get category code
    local category_code="${EVENT_CATEGORIES[$category]:-UNKNOWN}"

    # Build JSON log entry
    local log_entry
    log_entry=$(build_json_entry "$timestamp" "$event_id" "$category" "$category_code" "$level" "$message" "$extra_data")

    # Write to log file
    echo "$log_entry" >> "$AUDIT_LOG_FILE"

    # Optionally copy to stdout
    if [ "$AUDIT_STDOUT_COPY" = "true" ]; then
        echo "$log_entry"
    fi
}

# Build JSON log entry
build_json_entry() {
    local timestamp="$1"
    local event_id="$2"
    local category="$3"
    local category_code="$4"
    local level="$5"
    local message="$6"
    local extra_data="$7"

    # Escape message for JSON
    local escaped_message
    escaped_message=$(_json_escape "$message")

    # Build base JSON
    local json="{"
    json+="\"@timestamp\":\"$timestamp\","
    json+="\"event_id\":\"$event_id\","
    json+="\"category\":\"$category\","
    json+="\"category_code\":\"$category_code\","
    json+="\"level\":\"$level\","
    json+="\"message\":\"$escaped_message\""

    # Add optional fields
    if [ "$AUDIT_INCLUDE_PID" = "true" ]; then
        json+=",\"pid\":$$"
    fi

    if [ "$AUDIT_INCLUDE_HOST" = "true" ]; then
        local hostname
        hostname=$(hostname 2>/dev/null || echo "unknown")
        json+=",\"hostname\":\"$hostname\""
    fi

    # Add container metadata
    json+=",\"container_id\":\"${HOSTNAME:-unknown}\""
    json+=",\"container_name\":\"${CONTAINER_NAME:-unknown}\""

    # Merge extra data if valid JSON object (must start with { and end with })
    if [ -n "$extra_data" ] && [ "$extra_data" != "{}" ]; then
        # Validate structure: must start with { and end with }
        local trimmed
        trimmed=$(echo "$extra_data" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        if [[ "$trimmed" == "{"*"}" ]]; then
            # Strip outer braces and append
            local extra_content
            extra_content=$(echo "$trimmed" | sed 's/^{//; s/}$//')
            if [ -n "$extra_content" ]; then
                json+=",$extra_content"
            fi
        fi
    fi

    json+="}"
    echo "$json"
}

# ============================================================================
# Source sub-modules
# ============================================================================
_AUDIT_LOGGER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_AUDIT_LOGGER_DIR}/audit-logger-events.sh"
source "${_AUDIT_LOGGER_DIR}/audit-logger-shippers.sh"
source "${_AUDIT_LOGGER_DIR}/audit-logger-maintenance.sh"

# Export functions for use in other scripts
export -f _json_escape
export -f audit_log
export -f audit_init

# ============================================================================
# Auto-initialization
# ============================================================================

# Initialize on source if not already done
if [ "${AUDIT_INITIALIZED:-false}" != "true" ]; then
    audit_init
    export AUDIT_INITIALIZED=true
fi
