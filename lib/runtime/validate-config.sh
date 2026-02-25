#!/usr/bin/env bash
# Configuration Validation Framework
# Version: 2.0.0
#
# Description:
#   Runtime configuration validation system that validates environment variables,
#   checks formats, detects secrets, and ensures proper application configuration
#   before the container starts. Supports compliance mode validation for PCI-DSS,
#   HIPAA, FedRAMP, and CMMC frameworks.
#
# Usage:
#   source /opt/container-runtime/validate-config.sh
#   validate_configuration
#
# Configuration:
#   VALIDATE_CONFIG - Enable validation (true/false, default: false)
#   VALIDATE_CONFIG_STRICT - Fail on warnings (true/false, default: false)
#   VALIDATE_CONFIG_RULES - Path to custom validation rules file
#   VALIDATE_CONFIG_QUIET - Suppress informational messages (true/false, default: false)
#   COMPLIANCE_MODE - Compliance framework to validate (pci-dss, hipaa, fedramp, cmmc)
#   COMPLIANCE_REPORT_PATH - Path to write compliance report (optional)
#
# Features:
#   - Required environment variable validation
#   - Format validation (URLs, paths, ports, etc.)
#   - Secret detection (plaintext passwords/keys)
#   - Custom validation rules support
#   - Clear error messages with remediation hints
#   - Compliance mode validation (PCI-DSS, HIPAA, FedRAMP, CMMC)

set -eo pipefail

# ============================================================================
# Configuration
# ============================================================================

# Validation state
CV_ERRORS_FILE=$(mktemp)
readonly CV_ERRORS_FILE
CV_WARNINGS_FILE=$(mktemp)
readonly CV_WARNINGS_FILE
CV_ERROR_COUNT=0
CV_WARNING_COUNT=0

# Colors for output
readonly CV_RED='\033[0;31m'
readonly CV_YELLOW='\033[1;33m'
readonly CV_GREEN='\033[0;32m'
readonly CV_BLUE='\033[0;34m'
readonly CV_NC='\033[0m' # No Color

# Cleanup on exit
cv_cleanup() {
    command rm -f "$CV_ERRORS_FILE" "$CV_WARNINGS_FILE"
}
trap cv_cleanup EXIT

# ============================================================================
# Logging Functions
# ============================================================================

cv_info() {
    if [ "${VALIDATE_CONFIG_QUIET:-false}" != "true" ]; then
        echo -e "${CV_BLUE}ℹ${CV_NC} $*"
    fi
}

cv_error() {
    echo -e "${CV_RED}✗${CV_NC} $*" | tee -a "$CV_ERRORS_FILE" >&2
    CV_ERROR_COUNT=$((CV_ERROR_COUNT + 1))
}

cv_warning() {
    echo -e "${CV_YELLOW}⚠${CV_NC} $*" | tee -a "$CV_WARNINGS_FILE" >&2
    CV_WARNING_COUNT=$((CV_WARNING_COUNT + 1))
}

cv_success() {
    if [ "${VALIDATE_CONFIG_QUIET:-false}" != "true" ]; then
        echo -e "${CV_GREEN}✓${CV_NC} $*"
    fi
}

# ============================================================================
# Validation Functions
# ============================================================================

# Check if a variable is set and non-empty
cv_require_var() {
    local var_name="$1"
    local description="${2:-$var_name}"
    local remediation="${3:-Set the $var_name environment variable}"

    if [ -z "${!var_name:-}" ]; then
        cv_error "Required: $description"
        cv_error "  Variable: $var_name"
        cv_error "  Fix: $remediation"
        return 1
    fi

    cv_success "Required variable set: $var_name"
    return 0
}

# Validate URL format
cv_validate_url() {
    local var_name="$1"
    local required_scheme="${2:-}" # e.g., "https", "postgresql", "redis"
    local value="${!var_name:-}"

    if [ -z "$value" ]; then
        cv_warning "Variable $var_name is empty (skipping URL validation)"
        return 0
    fi

    # Basic URL pattern validation
    if [[ ! "$value" =~ ^[a-zA-Z][a-zA-Z0-9+.-]*:// ]]; then
        cv_error "Invalid URL format: $var_name"
        cv_error "  Value: $value"
        cv_error "  Expected: A valid URL with scheme (e.g., https://...)"
        return 1
    fi

    # Validate specific scheme if required
    if [ -n "$required_scheme" ]; then
        if [[ ! "$value" =~ ^${required_scheme}:// ]]; then
            cv_error "Invalid URL scheme: $var_name"
            cv_error "  Value: $value"
            cv_error "  Expected scheme: $required_scheme"
            return 1
        fi
    fi

    cv_success "Valid URL: $var_name"
    return 0
}

# Validate file/directory path
cv_validate_path() {
    local var_name="$1"
    local must_exist="${2:-false}" # true if path must exist
    local must_be_dir="${3:-false}" # true if must be directory
    local value="${!var_name:-}"

    if [ -z "$value" ]; then
        cv_warning "Variable $var_name is empty (skipping path validation)"
        return 0
    fi

    # Check if path is absolute
    if [[ ! "$value" =~ ^/ ]]; then
        cv_warning "Path is not absolute: $var_name=$value"
    fi

    # Check existence if required
    if [ "$must_exist" = "true" ]; then
        if [ ! -e "$value" ]; then
            cv_error "Path does not exist: $var_name"
            cv_error "  Value: $value"
            cv_error "  Fix: Create the path or update the variable"
            return 1
        fi

        # Check if should be directory
        if [ "$must_be_dir" = "true" ] && [ ! -d "$value" ]; then
            cv_error "Path is not a directory: $var_name"
            cv_error "  Value: $value"
            return 1
        fi
    fi

    cv_success "Valid path: $var_name"
    return 0
}

# Validate port number
cv_validate_port() {
    local var_name="$1"
    local value="${!var_name:-}"

    if [ -z "$value" ]; then
        cv_warning "Variable $var_name is empty (skipping port validation)"
        return 0
    fi

    # Check if numeric
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        cv_error "Invalid port (not numeric): $var_name"
        cv_error "  Value: $value"
        return 1
    fi

    # Check range (1-65535)
    if [ "$value" -lt 1 ] || [ "$value" -gt 65535 ]; then
        cv_error "Invalid port (out of range): $var_name"
        cv_error "  Value: $value"
        cv_error "  Valid range: 1-65535"
        return 1
    fi

    cv_success "Valid port: $var_name=$value"
    return 0
}

# Validate email format
cv_validate_email() {
    local var_name="$1"
    local value="${!var_name:-}"

    if [ -z "$value" ]; then
        cv_warning "Variable $var_name is empty (skipping email validation)"
        return 0
    fi

    # Basic email pattern
    if [[ ! "$value" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        cv_error "Invalid email format: $var_name"
        cv_error "  Value: $value"
        return 1
    fi

    cv_success "Valid email: $var_name"
    return 0
}

# Validate boolean value
cv_validate_boolean() {
    local var_name="$1"
    local value="${!var_name:-}"

    if [ -z "$value" ]; then
        cv_warning "Variable $var_name is empty (skipping boolean validation)"
        return 0
    fi

    # Check if valid boolean
    if [[ ! "$value" =~ ^(true|false|yes|no|1|0|TRUE|FALSE|YES|NO)$ ]]; then
        cv_error "Invalid boolean value: $var_name"
        cv_error "  Value: $value"
        cv_error "  Valid values: true, false, yes, no, 1, 0"
        return 1
    fi

    cv_success "Valid boolean: $var_name=$value"
    return 0
}

# ============================================================================
# Secret Detection
# ============================================================================

# Detect potential secrets in environment variables
cv_detect_secrets() {
    local var_name="$1"
    local value="${!var_name:-}"

    if [ -z "$value" ]; then
        return 0
    fi

    # Patterns that suggest hardcoded secrets (reserved for future use)
    # shellcheck disable=SC2034  # Reserved for future pattern matching
    local secret_patterns=(
        'password.*=.*[^$]'  # Hardcoded passwords
        'secret.*=.*[^$]'    # Hardcoded secrets
        'token.*=.*[^$]'     # Hardcoded tokens
        'key.*=.*[^$]'       # Hardcoded keys (but not key paths)
    )

    # Check if variable name suggests it might contain a secret
    local var_lower
    var_lower=$(echo "$var_name" | tr '[:upper:]' '[:lower:]')

    if [[ "$var_lower" =~ password|secret|token|apikey|api_key ]]; then
        # Check if value looks like a reference (e.g., ${SECRET} or /path/to/secret)
        if [[ "$value" =~ ^\$\{ ]] || [[ "$value" =~ ^/ ]]; then
            cv_info "Secret reference detected: $var_name (using reference: OK)"
            return 0
        fi

        # Check if value is very short (likely a placeholder)
        if [ ${#value} -lt 8 ]; then
            cv_warning "Potential placeholder secret: $var_name"
            cv_warning "  Value appears to be a placeholder (length: ${#value})"
            cv_warning "  Recommendation: Use a secret management system"
            return 0
        fi

        # Warn about potential plaintext secret
        cv_warning "Potential plaintext secret detected: $var_name"
        cv_warning "  Length: ${#value} characters"
        cv_warning "  Recommendation: Use environment variable references, secret files, or a secret management system"
        cv_warning "  Examples: \${SECRET_FROM_FILE}, /run/secrets/api-key, Vault/AWS Secrets Manager"
    fi

    return 0
}

# ============================================================================
# Custom Validation Rules
# ============================================================================

# Load and execute custom validation rules from file
cv_load_custom_rules() {
    local rules_file="${VALIDATE_CONFIG_RULES:-}"

    if [ -z "$rules_file" ]; then
        return 0
    fi

    if [ ! -f "$rules_file" ]; then
        cv_warning "Custom validation rules file not found: $rules_file"
        return 0
    fi

    cv_info "Loading custom validation rules from: $rules_file"

    # Source the rules file in a safe manner
    # shellcheck source=/dev/null
    source "$rules_file" || {
        cv_error "Failed to load custom validation rules"
        return 1
    }

    # Execute custom validation function if it exists
    if declare -f cv_custom_validations >/dev/null; then
        cv_info "Running custom validations..."
        cv_custom_validations || {
            cv_error "Custom validations failed"
            return 1
        }
    fi

    return 0
}

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
    if [ "${AUDIT_LOG_ENABLED:-false}" = "true" ] || [ -n "${AUDIT_LOG_PATH:-}" ]; then
        cv_compliance_check "Audit Logging" "pass" "$framework" "$requirement" \
            "Audit logging is enabled"

        # Check audit log destination
        if [ -n "${AUDIT_LOG_PATH:-}" ]; then
            if [ -d "$(dirname "${AUDIT_LOG_PATH}")" ]; then
                cv_compliance_check "Audit Log Path" "pass" "$framework" "$requirement" \
                    "Audit log path is valid: $AUDIT_LOG_PATH"
            else
                cv_compliance_check "Audit Log Path" "fail" "$framework" "$requirement" \
                    "Audit log directory does not exist" \
                    "Create directory: $(dirname "${AUDIT_LOG_PATH}")"
            fi
        fi
    else
        cv_compliance_check "Audit Logging" "fail" "$framework" "$requirement" \
            "Audit logging is not enabled" \
            "Set AUDIT_LOG_ENABLED=true and AUDIT_LOG_PATH=/path/to/audit.log"
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
    echo "  Compliance Validation: $(echo "$mode" | tr '[:lower:]' '[:upper:]')"
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
    echo "  Framework: $(echo "$mode" | tr '[:lower:]' '[:upper:]')"
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

# ============================================================================
# Main Validation Entry Point
# ============================================================================

# Run built-in URL and port validations from declarative lists
_run_builtin_validations() {
    local -a url_checks=("DATABASE_URL:postgresql" "REDIS_URL:redis")
    local -a port_checks=("PORT" "REDIS_PORT")
    local entry var scheme

    for entry in "${url_checks[@]}"; do
        var="${entry%%:*}"; scheme="${entry#*:}"
        [ -n "${!var:-}" ] && cv_validate_url "$var" "$scheme"
    done
    for var in "${port_checks[@]}"; do
        [ -n "${!var:-}" ] && cv_validate_port "$var"
    done
}

validate_configuration() {
    # Check if validation is enabled
    if [ "${VALIDATE_CONFIG:-false}" != "true" ]; then
        return 0
    fi

    echo ""
    echo "================================================================"
    echo "  Configuration Validation"
    echo "================================================================"
    echo ""

    # Reset counters
    CV_ERROR_COUNT=0
    CV_WARNING_COUNT=0
    : > "$CV_ERRORS_FILE"
    : > "$CV_WARNINGS_FILE"

    # Built-in URL/port validations
    _run_builtin_validations

    # Secret detection for common secret variables
    local secret_vars=(
        "API_KEY"
        "ANTHROPIC_API_KEY"
        "OPENAI_API_KEY"
        "CF_API_KEY"
        "SECRET_KEY"
        "DATABASE_PASSWORD"
        "JWT_SECRET"
        "SESSION_SECRET"
        "ENCRYPTION_KEY"
        "AWS_SECRET_ACCESS_KEY"
        "R2_SECRET_ACCESS_KEY"
        "S3_SECRET_KEY"
    )

    for var in "${secret_vars[@]}"; do
        cv_detect_secrets "$var"
    done

    # Load custom validation rules if provided
    cv_load_custom_rules

    # Run compliance validation if mode is set
    local compliance_result=0
    if [ -n "${COMPLIANCE_MODE:-}" ]; then
        cv_validate_compliance || compliance_result=$?
    fi

    # Print summary
    echo ""
    echo "================================================================"
    echo "  Validation Summary"
    echo "================================================================"

    if [ "$CV_ERROR_COUNT" -eq 0 ] && [ "$CV_WARNING_COUNT" -eq 0 ]; then
        echo -e "${CV_GREEN}✓ Configuration validation passed${CV_NC}"
        echo "  No errors or warnings found"
        return 0
    fi

    if [ "$CV_WARNING_COUNT" -gt 0 ]; then
        echo -e "${CV_YELLOW}⚠ Warnings: $CV_WARNING_COUNT${CV_NC}"
    fi

    if [ "$CV_ERROR_COUNT" -gt 0 ]; then
        echo -e "${CV_RED}✗ Errors: $CV_ERROR_COUNT${CV_NC}"
        echo ""
        echo "Configuration validation failed. Please fix the errors above."

        # Exit with error code
        return 1
    fi

    # Check if we should fail on warnings in strict mode
    if [ "${VALIDATE_CONFIG_STRICT:-false}" = "true" ] && [ "$CV_WARNING_COUNT" -gt 0 ]; then
        echo ""
        echo "Strict mode enabled: Treating warnings as errors"
        return 1
    fi

    echo -e "${CV_GREEN}✓ Configuration validation passed${CV_NC}"
    echo "  (with warnings)"

    # Return compliance failure if applicable
    if [ "$compliance_result" -ne 0 ]; then
        return "$compliance_result"
    fi

    return 0
}

# Export functions for use in custom rules files
export -f cv_require_var
export -f cv_validate_url
export -f cv_validate_path
export -f cv_validate_port
export -f cv_validate_email
export -f cv_validate_boolean
export -f cv_detect_secrets
export -f cv_error
export -f cv_warning
export -f cv_success
export -f cv_info
export -f cv_compliance_check
export -f cv_validate_compliance
