#!/usr/bin/env bash
# Audit Logger - Maintenance Functions
#
# Provides log rotation, integrity verification, and retention policy functions.
# Part of the audit logging system (see audit-logger.sh).
#
# Usage:
#   source /opt/container-runtime/audit-logger.sh  # Sources this automatically
#   audit_rotate 100 30

# Prevent multiple sourcing
if [ -n "${_AUDIT_LOGGER_MAINTENANCE_LOADED:-}" ]; then
    return 0
fi
_AUDIT_LOGGER_MAINTENANCE_LOADED=1

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
export -f audit_rotate audit_verify_integrity get_retention_policy
