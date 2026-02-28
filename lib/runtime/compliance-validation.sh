#!/usr/bin/env bash
# Compliance Mode Validation
#
# Provides compliance framework validation for PCI-DSS, HIPAA, FedRAMP, and CMMC.
# Part of the configuration validation system (see validate-config.sh).
#
# Usage:
#   source /opt/container-runtime/compliance-validation.sh
#   cv_validate_compliance

# ============================================================================
# Compliance Mode Validation
# ============================================================================

# Compliance state
CV_COMPLIANCE_CHECKS=0
CV_COMPLIANCE_PASSED=0
CV_COMPLIANCE_FAILED=0
CV_COMPLIANCE_REPORT=""

# Record a compliance check result
cv_compliance_check() {
    local check_name="$1"
    local check_result="$2"  # pass, fail, warn
    local framework="$3"
    local requirement="$4"
    local description="$5"
    local remediation="${6:-}"

    CV_COMPLIANCE_CHECKS=$((CV_COMPLIANCE_CHECKS + 1))

    case "$check_result" in
        pass)
            CV_COMPLIANCE_PASSED=$((CV_COMPLIANCE_PASSED + 1))
            cv_success "[$framework] $check_name: $description"
            CV_COMPLIANCE_REPORT+="PASS|$framework|$requirement|$check_name|$description\n"
            ;;
        fail)
            CV_COMPLIANCE_FAILED=$((CV_COMPLIANCE_FAILED + 1))
            cv_error "[$framework] $check_name: $description"
            if [ -n "$remediation" ]; then
                cv_error "  Fix: $remediation"
            fi
            CV_COMPLIANCE_REPORT+="FAIL|$framework|$requirement|$check_name|$description|$remediation\n"
            ;;
        warn)
            cv_warning "[$framework] $check_name: $description"
            CV_COMPLIANCE_REPORT+="WARN|$framework|$requirement|$check_name|$description\n"
            ;;
    esac
}

# Check TLS/encryption settings
cv_check_encryption() {
    local framework="$1"
    local requirement="$2"

    # Check TLS is enabled
    if [ "${TLS_ENABLED:-false}" = "true" ] || [ "${SSL_ENABLED:-false}" = "true" ]; then
        cv_compliance_check "TLS Enabled" "pass" "$framework" "$requirement" \
            "Transport encryption is enabled"
    else
        cv_compliance_check "TLS Enabled" "fail" "$framework" "$requirement" \
            "Transport encryption is not enabled" \
            "Set TLS_ENABLED=true or configure TLS in your application"
    fi

    # Check TLS version (minimum 1.2)
    local tls_version="${TLS_MIN_VERSION:-${SSL_MIN_VERSION:-}}"
    if [ -n "$tls_version" ]; then
        if [[ "$tls_version" =~ ^(1\.2|1\.3|TLSv1\.2|TLSv1\.3)$ ]]; then
            cv_compliance_check "TLS Version" "pass" "$framework" "$requirement" \
                "TLS version $tls_version meets minimum requirements"
        else
            cv_compliance_check "TLS Version" "fail" "$framework" "$requirement" \
                "TLS version $tls_version is below minimum (1.2)" \
                "Set TLS_MIN_VERSION=1.2 or higher"
        fi
    fi

    # Check encryption at rest
    if [ "${ENCRYPTION_AT_REST:-false}" = "true" ] || [ -n "${ENCRYPTION_KEY:-}" ]; then
        cv_compliance_check "Encryption at Rest" "pass" "$framework" "$requirement" \
            "Data encryption at rest is configured"
    else
        cv_compliance_check "Encryption at Rest" "warn" "$framework" "$requirement" \
            "Encryption at rest not explicitly configured"
    fi
}

# Check audit logging
cv_check_audit_logging() {
    local framework="$1"
    local requirement="$2"

    # Check if audit logging is enabled
    if [ "${ENABLE_AUDIT_LOGGING:-false}" = "true" ] || [ -n "${AUDIT_LOG_FILE:-}" ]; then
        cv_compliance_check "Audit Logging" "pass" "$framework" "$requirement" \
            "Audit logging is enabled"

        # Check audit log destination
        if [ -n "${AUDIT_LOG_FILE:-}" ]; then
            if [ -d "$(dirname "${AUDIT_LOG_FILE}")" ]; then
                cv_compliance_check "Audit Log Path" "pass" "$framework" "$requirement" \
                    "Audit log path is valid: $AUDIT_LOG_FILE"
            else
                cv_compliance_check "Audit Log Path" "fail" "$framework" "$requirement" \
                    "Audit log directory does not exist" \
                    "Create directory: $(dirname "${AUDIT_LOG_FILE}")"
            fi
        fi
    else
        cv_compliance_check "Audit Logging" "fail" "$framework" "$requirement" \
            "Audit logging is not enabled" \
            "Set ENABLE_AUDIT_LOGGING=true and AUDIT_LOG_FILE=/path/to/audit.log"
    fi

    # Check log retention
    if [ -n "${LOG_RETENTION_DAYS:-}" ]; then
        if [ "${LOG_RETENTION_DAYS}" -ge 90 ]; then
            cv_compliance_check "Log Retention" "pass" "$framework" "$requirement" \
                "Log retention period is ${LOG_RETENTION_DAYS} days"
        else
            cv_compliance_check "Log Retention" "warn" "$framework" "$requirement" \
                "Log retention (${LOG_RETENTION_DAYS} days) may be insufficient for compliance"
        fi
    fi
}

# Check resource limits
cv_check_resource_limits() {
    local framework="$1"
    local requirement="$2"

    # Check memory limits
    if [ -n "${MEMORY_LIMIT:-}" ]; then
        cv_compliance_check "Memory Limit" "pass" "$framework" "$requirement" \
            "Memory limit configured: $MEMORY_LIMIT"
    else
        cv_compliance_check "Memory Limit" "warn" "$framework" "$requirement" \
            "Memory limit not configured"
    fi

    # Check CPU limits
    if [ -n "${CPU_LIMIT:-}" ]; then
        cv_compliance_check "CPU Limit" "pass" "$framework" "$requirement" \
            "CPU limit configured: $CPU_LIMIT"
    else
        cv_compliance_check "CPU Limit" "warn" "$framework" "$requirement" \
            "CPU limit not configured"
    fi
}

# Check security context
cv_check_security_context() {
    local framework="$1"
    local requirement="$2"

    # Check non-root user
    if [ "$(id -u)" -ne 0 ]; then
        cv_compliance_check "Non-root User" "pass" "$framework" "$requirement" \
            "Container running as non-root user (UID: $(id -u))"
    else
        cv_compliance_check "Non-root User" "fail" "$framework" "$requirement" \
            "Container is running as root" \
            "Configure container to run as non-root user"
    fi

    # Check privileged mode (via environment hint)
    if [ "${CONTAINER_PRIVILEGED:-false}" = "true" ]; then
        cv_compliance_check "Privileged Mode" "fail" "$framework" "$requirement" \
            "Container is running in privileged mode" \
            "Remove privileged: true from container security context"
    else
        cv_compliance_check "Privileged Mode" "pass" "$framework" "$requirement" \
            "Container is not running in privileged mode"
    fi

    # Check read-only filesystem
    if [ "${READ_ONLY_ROOT_FS:-false}" = "true" ]; then
        cv_compliance_check "Read-only Filesystem" "pass" "$framework" "$requirement" \
            "Root filesystem is read-only"
    else
        cv_compliance_check "Read-only Filesystem" "warn" "$framework" "$requirement" \
            "Root filesystem is not read-only"
    fi
}

# Check health monitoring
cv_check_health_monitoring() {
    local framework="$1"
    local requirement="$2"

    # Check if healthcheck is configured
    if [ -n "${HEALTHCHECK_ENABLED:-}" ] && [ "${HEALTHCHECK_ENABLED}" = "true" ]; then
        cv_compliance_check "Health Check" "pass" "$framework" "$requirement" \
            "Health check is configured"
    elif [ -f "/opt/container-runtime/healthcheck.sh" ]; then
        cv_compliance_check "Health Check" "pass" "$framework" "$requirement" \
            "Health check script is present"
    else
        cv_compliance_check "Health Check" "warn" "$framework" "$requirement" \
            "Health check may not be configured"
    fi
}

# Check network security
cv_check_network_security() {
    local framework="$1"
    local requirement="$2"

    # Check network policy hints
    if [ "${NETWORK_POLICY_ENFORCED:-false}" = "true" ]; then
        cv_compliance_check "Network Policy" "pass" "$framework" "$requirement" \
            "Network policies are enforced"
    else
        cv_compliance_check "Network Policy" "warn" "$framework" "$requirement" \
            "Network policy enforcement not confirmed"
    fi
}

# Check backup configuration
cv_check_backup_config() {
    local framework="$1"
    local requirement="$2"

    if [ -n "${BACKUP_ENABLED:-}" ] && [ "${BACKUP_ENABLED}" = "true" ]; then
        cv_compliance_check "Backup Configuration" "pass" "$framework" "$requirement" \
            "Backup is configured"

        # Check backup schedule
        if [ -n "${BACKUP_SCHEDULE:-}" ]; then
            cv_compliance_check "Backup Schedule" "pass" "$framework" "$requirement" \
                "Backup schedule: $BACKUP_SCHEDULE"
        fi
    else
        cv_compliance_check "Backup Configuration" "warn" "$framework" "$requirement" \
            "Backup configuration not detected"
    fi
}

# Compliance framework registry: framework → "check:requirement_id ..."
# Each entry maps a cv_check_* function suffix to a requirement identifier.
declare -A CV_FRAMEWORK_CHECKS
CV_FRAMEWORK_CHECKS=(
    [PCI-DSS]="encryption:4.1 audit_logging:10.1 security_context:6.2 resource_limits:12.1 health_monitoring:11.4"
    [HIPAA]="encryption:164.312(e)(1) audit_logging:164.312(b) security_context:164.312(a)(1) backup_config:164.308(a)(7) health_monitoring:164.312(c)(1)"
    [FedRAMP]="encryption:SC-8 audit_logging:AU-2 resource_limits:SC-4 security_context:AC-6 network_security:SC-7 backup_config:CP-9 health_monitoring:SI-4"
    [CMMC]="encryption:SC.L2-3.13.8 audit_logging:AU.L2-3.3.1 security_context:CM.L2-3.4.2 resource_limits:SC.L2-3.13.4 health_monitoring:SI.L2-3.14.3"
)

# Generic compliance framework validator
cv_validate_framework() {
    local framework="$1"
    local checks="${CV_FRAMEWORK_CHECKS[$framework]:-}"

    if [ -z "$checks" ]; then
        cv_error "No checks defined for framework: $framework"
        return 1
    fi

    cv_info "Validating ${framework} compliance requirements..."

    for entry in $checks; do
        local check_func="cv_check_${entry%%:*}"
        local requirement_id="${entry#*:}"
        "$check_func" "$framework" "$requirement_id"
    done
}

# Generate compliance report
cv_generate_compliance_report() {
    local report_path="${COMPLIANCE_REPORT_PATH:-}"

    if [ -z "$report_path" ]; then
        return 0
    fi

    local report_dir
    report_dir=$(dirname "$report_path")
    if [ ! -d "$report_dir" ]; then
        mkdir -p "$report_dir"
    fi

    {
        echo "# Compliance Validation Report"
        echo "# Generated: $(date -Iseconds)"
        echo "# Framework: ${COMPLIANCE_MODE:-none}"
        echo "# Total Checks: $CV_COMPLIANCE_CHECKS"
        echo "# Passed: $CV_COMPLIANCE_PASSED"
        echo "# Failed: $CV_COMPLIANCE_FAILED"
        echo "#"
        echo "# Format: STATUS|FRAMEWORK|REQUIREMENT|CHECK|DESCRIPTION|REMEDIATION"
        echo "#"
        echo -e "$CV_COMPLIANCE_REPORT"
    } > "$report_path"

    cv_info "Compliance report written to: $report_path"
}

# Main compliance validation function
cv_validate_compliance() {
    local mode="${COMPLIANCE_MODE:-}"

    if [ -z "$mode" ]; then
        return 0
    fi

    echo ""
    echo "================================================================"
    echo "  Compliance Validation: $(echo "$mode" | command tr '[:lower:]' '[:upper:]')"
    echo "================================================================"
    echo ""

    # Reset compliance counters
    CV_COMPLIANCE_CHECKS=0
    CV_COMPLIANCE_PASSED=0
    CV_COMPLIANCE_FAILED=0
    CV_COMPLIANCE_REPORT=""

    # Normalize mode to registry key
    local framework_key
    case "$mode" in
        pci-dss|pci_dss|pcidss) framework_key="PCI-DSS" ;;
        hipaa) framework_key="HIPAA" ;;
        fedramp) framework_key="FedRAMP" ;;
        cmmc|cmmc-l2) framework_key="CMMC" ;;
        *)
            cv_error "Unknown compliance mode: $mode"
            cv_error "Supported modes: pci-dss, hipaa, fedramp, cmmc"
            return 1
            ;;
    esac

    cv_validate_framework "$framework_key"

    # Generate report if path specified
    cv_generate_compliance_report

    # Print compliance summary
    echo ""
    echo "================================================================"
    echo "  Compliance Summary"
    echo "================================================================"
    echo "  Framework: $(echo "$mode" | command tr '[:lower:]' '[:upper:]')"
    echo "  Total Checks: $CV_COMPLIANCE_CHECKS"
    echo -e "  ${CV_GREEN}Passed: $CV_COMPLIANCE_PASSED${CV_NC}"

    if [ "$CV_COMPLIANCE_FAILED" -gt 0 ]; then
        echo -e "  ${CV_RED}Failed: $CV_COMPLIANCE_FAILED${CV_NC}"
        return 1
    fi

    echo ""
    echo -e "${CV_GREEN}✓ Compliance validation passed${CV_NC}"
    return 0
}

# Export compliance functions
export -f cv_compliance_check
export -f cv_validate_compliance
