#!/usr/bin/env bash
# secret-detection.sh — Detect potential plaintext secrets in environment variables
#
# Provides: cv_detect_secrets
#
# Sourced by validate-config.sh; relies on cv_info/cv_warning being defined
# in the parent script.

# Detect potential secrets in environment variables
cv_detect_secrets() {
    local var_name="$1"
    local value="${!var_name:-}"

    if [ -z "$value" ]; then
        return 0
    fi

    # Check if variable name suggests it might contain a secret
    local var_lower
    var_lower=$(echo "$var_name" | command tr '[:upper:]' '[:lower:]')

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
