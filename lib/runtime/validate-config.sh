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
    echo -e "${CV_RED}✗${CV_NC} $*" | command tee -a "$CV_ERRORS_FILE" >&2
    CV_ERROR_COUNT=$((CV_ERROR_COUNT + 1))
}

cv_warning() {
    echo -e "${CV_YELLOW}⚠${CV_NC} $*" | command tee -a "$CV_WARNINGS_FILE" >&2
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

# Resolve directory for sourcing sibling modules
# At runtime this file lives at /opt/container-runtime/validate-config.sh
_VALIDATE_CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source format validators (cv_validate_url, cv_validate_path, cv_validate_port,
# cv_validate_email, cv_validate_boolean)
source "${_VALIDATE_CONFIG_DIR}/format-validators.sh"

# Source secret detection (cv_detect_secrets)
source "${_VALIDATE_CONFIG_DIR}/secret-detection.sh"

# ============================================================================
# Custom Validation Rules
# ============================================================================

# Trusted directory prefix for custom validation rules
readonly CV_TRUSTED_RULES_DIR="/etc/container/"

# Load and execute custom validation rules from file
cv_load_custom_rules() {
    local rules_file="${VALIDATE_CONFIG_RULES:-}"

    if [ -z "$rules_file" ]; then
        return 0
    fi

    # Require absolute path
    if [[ "$rules_file" != /* ]]; then
        cv_error "Custom validation rules path must be absolute: $rules_file"
        return 1
    fi

    if [ ! -f "$rules_file" ]; then
        cv_warning "Custom validation rules file not found: $rules_file"
        return 0
    fi

    # Canonicalize path to resolve symlinks and ../ traversal
    local resolved_path
    resolved_path="$(realpath --canonicalize-existing "$rules_file" 2>/dev/null)" || {
        cv_error "Cannot resolve custom validation rules path: $rules_file"
        return 1
    }

    # Verify path is within trusted directory
    if [[ "$resolved_path" != "${CV_TRUSTED_RULES_DIR}"* ]]; then
        cv_error "Custom validation rules must be under ${CV_TRUSTED_RULES_DIR}: $resolved_path"
        return 1
    fi

    # Verify file is owned by root
    local file_owner
    file_owner="$(stat -c '%u' "$resolved_path" 2>/dev/null)" || {
        cv_error "Cannot check ownership of custom validation rules: $resolved_path"
        return 1
    }
    if [ "$file_owner" != "0" ]; then
        cv_error "Custom validation rules must be owned by root (uid 0): $resolved_path (owner: $file_owner)"
        return 1
    fi

    cv_info "Loading custom validation rules from: $resolved_path"

    # Source the rules file
    # shellcheck source=/dev/null
    source "$resolved_path" || {
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

# Source compliance validation module
if [ -f "${_VALIDATE_CONFIG_DIR}/compliance-validation.sh" ]; then
    source "${_VALIDATE_CONFIG_DIR}/compliance-validation.sh"
fi

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
