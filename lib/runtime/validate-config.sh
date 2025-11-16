#!/usr/bin/env bash
# Configuration Validation Framework
# Version: 1.0.0
#
# Description:
#   Runtime configuration validation system that validates environment variables,
#   checks formats, detects secrets, and ensures proper application configuration
#   before the container starts.
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
#
# Features:
#   - Required environment variable validation
#   - Format validation (URLs, paths, ports, etc.)
#   - Secret detection (plaintext passwords/keys)
#   - Custom validation rules support
#   - Clear error messages with remediation hints

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
cleanup_validation_files() {
    command rm -f "$CV_ERRORS_FILE" "$CV_WARNINGS_FILE"
}
trap cleanup_validation_files EXIT

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
# Main Validation Entry Point
# ============================================================================

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

    # Example built-in validations (these can be customized per application)
    # Users should override this function or provide custom rules

    # Database validation example
    if [ -n "${DATABASE_URL:-}" ]; then
        cv_validate_url DATABASE_URL "postgresql"
    fi

    # Redis validation example
    if [ -n "${REDIS_URL:-}" ]; then
        cv_validate_url REDIS_URL "redis"
    fi

    # Port validation examples
    if [ -n "${PORT:-}" ]; then
        cv_validate_port PORT
    fi

    if [ -n "${REDIS_PORT:-}" ]; then
        cv_validate_port REDIS_PORT
    fi

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
        if [ -n "${!var:-}" ]; then
            cv_detect_secrets "$var"
        fi
    done

    # Load custom validation rules if provided
    cv_load_custom_rules

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
