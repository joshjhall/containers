#!/usr/bin/env bash
# Audit Logger - Specialized Event Functions
#
# Provides specialized audit functions for different event categories.
# Part of the audit logging system (see audit-logger.sh).
#
# Usage:
#   source /opt/container-runtime/audit-logger.sh  # Sources this automatically
#   audit_auth "login" "admin" "success" '{}'

# Prevent multiple sourcing
if [ -n "${_AUDIT_LOGGER_EVENTS_LOADED:-}" ]; then
    return 0
fi
_AUDIT_LOGGER_EVENTS_LOADED=1

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

# Export functions for use in other scripts
export -f audit_auth audit_authz audit_data_access audit_config
export -f audit_security audit_network audit_file audit_process audit_compliance
