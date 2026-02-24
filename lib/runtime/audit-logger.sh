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
    event_id=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$(date +%s)-$$-$RANDOM")

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
# Specialized Audit Functions
# ============================================================================

# Authentication events
audit_auth() {
    local action="$1"      # login, logout, failed_login, mfa_challenge
    local user="$2"
    local result="$3"      # success, failure
    local details="$4"

    local extra_data
    extra_data="{\"action\":\"$(_json_escape "$action")\",\"user\":\"$(_json_escape "$user")\",\"result\":\"$(_json_escape "$result")\""
    if [ -n "$details" ]; then
        extra_data+=",\"details\":$details"
    fi
    extra_data+="}"

    local level="info"
    [ "$result" = "failure" ] && level="warn"

    audit_log "authentication" "$level" "Authentication event: $action" "$extra_data"
}

# Authorization/access control events
audit_authz() {
    local resource="$1"    # Resource being accessed
    local action="$2"      # read, write, delete, execute
    local user="$3"
    local result="$4"      # granted, denied
    local reason="$5"

    local extra_data
    extra_data="{\"resource\":\"$(_json_escape "$resource")\",\"action\":\"$(_json_escape "$action")\",\"user\":\"$(_json_escape "$user")\",\"result\":\"$(_json_escape "$result")\""
    if [ -n "$reason" ]; then
        extra_data+=",\"reason\":\"$(_json_escape "$reason")\""
    fi
    extra_data+="}"

    local level="info"
    [ "$result" = "denied" ] && level="warn"

    audit_log "authorization" "$level" "Authorization: $action on $resource" "$extra_data"
}

# Data access events (for sensitive data tracking)
audit_data_access() {
    local data_type="$1"   # pii, phi, financial, credentials
    local operation="$2"   # read, write, delete, export
    local user="$3"
    local record_count="$4"
    local purpose="$5"

    local extra_data
    extra_data="{\"data_type\":\"$(_json_escape "$data_type")\",\"operation\":\"$(_json_escape "$operation")\",\"user\":\"$(_json_escape "$user")\""
    if [ -n "$record_count" ]; then
        extra_data+=",\"record_count\":$record_count"
    fi
    if [ -n "$purpose" ]; then
        extra_data+=",\"purpose\":\"$(_json_escape "$purpose")\""
    fi
    extra_data+="}"

    audit_log "data_access" "info" "Data access: $operation on $data_type" "$extra_data"
}

# Configuration change events
audit_config() {
    local component="$1"   # Component being configured
    local change_type="$2" # created, modified, deleted
    local user="$3"
    local old_value="$4"
    local new_value="$5"

    local extra_data
    extra_data="{\"component\":\"$(_json_escape "$component")\",\"change_type\":\"$(_json_escape "$change_type")\",\"user\":\"$(_json_escape "$user")\""
    if [ -n "$old_value" ]; then
        extra_data+=",\"old_value\":\"$(_json_escape "$old_value")\""
    fi
    if [ -n "$new_value" ]; then
        extra_data+=",\"new_value\":\"$(_json_escape "$new_value")\""
    fi
    extra_data+="}"

    audit_log "configuration" "info" "Configuration change: $change_type $component" "$extra_data"
}

# Security events (anomalies, violations, incidents)
audit_security() {
    local event_type="$1"  # anomaly, violation, incident, threat
    local severity="$2"    # low, medium, high, critical
    local description="$3"
    local indicators="$4"  # JSON object with IOCs

    local extra_data
    extra_data="{\"event_type\":\"$(_json_escape "$event_type")\",\"severity\":\"$(_json_escape "$severity")\""
    if [ -n "$indicators" ]; then
        extra_data+=",\"indicators\":$indicators"
    fi
    extra_data+="}"

    local level="warn"
    [ "$severity" = "high" ] || [ "$severity" = "critical" ] && level="error"

    audit_log "security" "$level" "Security event: $description" "$extra_data"
}

# Network events
audit_network() {
    local event_type="$1"  # connection, blocked, dns, tls
    local direction="$2"   # inbound, outbound
    local src_ip="$3"
    local dst_ip="$4"
    local dst_port="$5"
    local protocol="$6"

    local extra_data
    extra_data="{\"event_type\":\"$(_json_escape "$event_type")\",\"direction\":\"$(_json_escape "$direction")\""
    [ -n "$src_ip" ] && extra_data+=",\"src_ip\":\"$(_json_escape "$src_ip")\""
    [ -n "$dst_ip" ] && extra_data+=",\"dst_ip\":\"$(_json_escape "$dst_ip")\""
    [ -n "$dst_port" ] && extra_data+=",\"dst_port\":$dst_port"
    [ -n "$protocol" ] && extra_data+=",\"protocol\":\"$(_json_escape "$protocol")\""
    extra_data+="}"

    audit_log "network" "info" "Network event: $event_type $direction" "$extra_data"
}

# File integrity events
audit_file() {
    local event_type="$1"  # created, modified, deleted, permission_change
    local file_path="$2"
    local user="$3"
    local checksum="$4"

    local extra_data
    extra_data="{\"event_type\":\"$(_json_escape "$event_type")\",\"file_path\":\"$(_json_escape "$file_path")\",\"user\":\"$(_json_escape "$user")\""
    if [ -n "$checksum" ]; then
        extra_data+=",\"checksum\":\"$(_json_escape "$checksum")\""
    fi
    extra_data+="}"

    audit_log "file" "info" "File event: $event_type $file_path" "$extra_data"
}

# Process events
audit_process() {
    local event_type="$1"  # started, stopped, killed, crashed
    local process_name="$2"
    local pid="$3"
    local exit_code="$4"
    local user="$5"

    local extra_data
    extra_data="{\"event_type\":\"$(_json_escape "$event_type")\",\"process_name\":\"$(_json_escape "$process_name")\""
    [ -n "$pid" ] && extra_data+=",\"process_pid\":$pid"
    [ -n "$exit_code" ] && extra_data+=",\"exit_code\":$exit_code"
    [ -n "$user" ] && extra_data+=",\"user\":\"$(_json_escape "$user")\""
    extra_data+="}"

    audit_log "process" "info" "Process event: $event_type $process_name" "$extra_data"
}

# Compliance events (for audit trail)
audit_compliance() {
    local framework="$1"   # soc2, hipaa, pci, gdpr, fedramp
    local requirement="$2" # Requirement ID (e.g., CC7.2, 164.312)
    local status="$3"      # compliant, non_compliant, exception
    local evidence="$4"    # JSON object with supporting evidence

    local extra_data
    extra_data="{\"framework\":\"$(_json_escape "$framework")\",\"requirement\":\"$(_json_escape "$requirement")\",\"status\":\"$(_json_escape "$status")\""
    if [ -n "$evidence" ]; then
        extra_data+=",\"evidence\":$evidence"
    fi
    extra_data+="}"

    local level="info"
    [ "$status" = "non_compliant" ] && level="error"

    audit_log "compliance" "$level" "Compliance check: $framework $requirement" "$extra_data"
}

# ============================================================================
# Log Shipping Support
# ============================================================================

# Get log shipper configuration for different backends
get_fluentd_config() {
    cat << 'EOF'
<source>
  @type tail
  path /var/log/audit/container-audit.log
  pos_file /var/log/audit/container-audit.log.pos
  tag container.audit
  <parse>
    @type json
    time_key @timestamp
    time_format %Y-%m-%dT%H:%M:%S.%NZ
  </parse>
</source>

<match container.audit>
  @type forward
  <server>
    host ${FLUENTD_HOST}
    port ${FLUENTD_PORT}
  </server>
  <buffer>
    @type file
    path /var/log/fluentd-buffer
    flush_interval 5s
  </buffer>
</match>
EOF
}

# Get CloudWatch Logs agent configuration
get_cloudwatch_config() {
    cat << 'EOF'
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/audit/container-audit.log",
            "log_group_name": "${CLOUDWATCH_LOG_GROUP}",
            "log_stream_name": "${CLOUDWATCH_LOG_STREAM}",
            "timestamp_format": "%Y-%m-%dT%H:%M:%S.%fZ",
            "multi_line_start_pattern": "^{"
          }
        ]
      }
    }
  }
}
EOF
}

# Get Grafana Loki configuration (Promtail)
get_loki_config() {
    cat << 'EOF'
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /tmp/positions.yaml

clients:
  - url: ${LOKI_URL}/loki/api/v1/push

scrape_configs:
  - job_name: container_audit
    static_configs:
      - targets:
          - localhost
        labels:
          job: container-audit
          __path__: /var/log/audit/container-audit.log
    pipeline_stages:
      - json:
          expressions:
            level: level
            category: category
            event_id: event_id
      - labels:
          level:
          category:
EOF
}

# ============================================================================
# Utility Functions
# ============================================================================

# Rotate audit logs (call from cron or logrotate)
audit_rotate() {
    local max_size_mb="${1:-100}"
    local keep_count="${2:-30}"

    local log_size
    log_size=$(stat -f%z "$AUDIT_LOG_FILE" 2>/dev/null || stat -c%s "$AUDIT_LOG_FILE" 2>/dev/null || echo 0)
    local max_size_bytes=$((max_size_mb * 1024 * 1024))

    if [ "$log_size" -gt "$max_size_bytes" ]; then
        local timestamp
        timestamp=$(date +%Y%m%d-%H%M%S)
        local rotated_file="${AUDIT_LOG_FILE}.${timestamp}"

        # Rotate current log
        mv "$AUDIT_LOG_FILE" "$rotated_file"
        touch "$AUDIT_LOG_FILE"
        chmod 640 "$AUDIT_LOG_FILE"

        # Compress rotated log
        gzip "$rotated_file"

        # Calculate checksum for integrity
        local checksum
        checksum=$(sha256sum "${rotated_file}.gz" | cut -d' ' -f1)
        echo "$checksum  ${rotated_file}.gz" >> "${AUDIT_LOG_FILE}.checksums"

        # Remove old logs beyond keep count
        # shellcheck disable=SC2012
        ls -t "${AUDIT_LOG_FILE}".*.gz 2>/dev/null | tail -n +$((keep_count + 1)) | xargs -r rm -f

        audit_log "system" "info" "Audit log rotated" "{\"rotated_to\":\"${rotated_file}.gz\",\"checksum\":\"$checksum\"}"
    fi
}

# Verify log integrity
audit_verify_integrity() {
    local checksum_file="${AUDIT_LOG_FILE}.checksums"

    if [ ! -f "$checksum_file" ]; then
        echo "No checksum file found"
        return 1
    fi

    local failed=0
    while IFS= read -r line; do
        local expected_checksum file_path
        expected_checksum=$(echo "$line" | cut -d' ' -f1)
        file_path=$(echo "$line" | cut -d' ' -f3)

        if [ -f "$file_path" ]; then
            local actual_checksum
            actual_checksum=$(sha256sum "$file_path" | cut -d' ' -f1)
            if [ "$expected_checksum" != "$actual_checksum" ]; then
                echo "INTEGRITY VIOLATION: $file_path"
                audit_log "security" "critical" "Audit log integrity violation detected" "{\"file\":\"$file_path\"}"
                failed=1
            fi
        fi
    done < "$checksum_file"

    return $failed
}

# Get retention policy for framework
get_retention_policy() {
    local framework="$1"

    case "$framework" in
        soc2)
            echo "365"  # 12 months
            ;;
        hipaa)
            echo "2190" # 6 years
            ;;
        pci)
            echo "365"  # 1 year (90 days immediately available)
            ;;
        gdpr)
            echo "0"    # As long as necessary (application-defined)
            ;;
        fedramp)
            echo "1095" # 3 years
            ;;
        *)
            echo "365"  # Default: 1 year
            ;;
    esac
}

# Export functions for use in other scripts
export -f _json_escape
export -f audit_log audit_auth audit_authz audit_data_access audit_config
export -f audit_security audit_network audit_file audit_process audit_compliance
export -f audit_init audit_rotate audit_verify_integrity get_retention_policy

# ============================================================================
# Auto-initialization
# ============================================================================

# Initialize on source if not already done
if [ "${AUDIT_INITIALIZED:-false}" != "true" ]; then
    audit_init
    export AUDIT_INITIALIZED=true
fi
