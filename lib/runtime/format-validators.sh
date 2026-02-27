#!/usr/bin/env bash
# format-validators.sh — Format validation functions for configuration values
#
# Provides: cv_validate_url, cv_validate_path, cv_validate_port,
#           cv_validate_email, cv_validate_boolean
#
# Sourced by validate-config.sh; relies on cv_error/cv_warning/cv_success
# being defined in the parent script.

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
