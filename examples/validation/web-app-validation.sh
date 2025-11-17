#!/usr/bin/env bash
# Web Application Validation Rules
#
# This example demonstrates configuration validation for a typical web application
# that uses PostgreSQL, Redis, and external APIs.
#
# Usage:
#   Set VALIDATE_CONFIG_RULES=/path/to/web-app-validation.sh in your environment

cv_custom_validations() {
    echo "Running web application configuration validation..."

    # ========================================================================
    # Required Variables
    # ========================================================================

    cv_require_var DATABASE_URL \
        "PostgreSQL database connection string" \
        "Set DATABASE_URL to postgresql://user:pass@host:port/dbname"

    cv_require_var REDIS_URL \
        "Redis connection string for sessions and caching" \
        "Set REDIS_URL to redis://host:port/db"

    cv_require_var SECRET_KEY \
        "Application secret key for session encryption" \
        "Generate a secure random key: openssl rand -hex 32"

    # ========================================================================
    # URL Validation
    # ========================================================================

    # Validate database URL has correct scheme
    cv_validate_url DATABASE_URL "postgresql"

    # Validate Redis URL has correct scheme
    cv_validate_url REDIS_URL "redis"

    # Optional: API endpoints
    if [ -n "${API_ENDPOINT:-}" ]; then
        cv_validate_url API_ENDPOINT "https"
    fi

    # ========================================================================
    # Port Validation
    # ========================================================================

    # Application port (optional, defaults to 3000)
    if [ -n "${PORT:-}" ]; then
        cv_validate_port PORT
    fi

    # Metrics port (optional)
    if [ -n "${METRICS_PORT:-}" ]; then
        cv_validate_port METRICS_PORT
    fi

    # ========================================================================
    # Secret Detection
    # ========================================================================

    # Warn about plaintext secrets
    cv_detect_secrets SECRET_KEY
    cv_detect_secrets SESSION_SECRET

    # Check API keys
    if [ -n "${OPENAI_API_KEY:-}" ]; then
        cv_detect_secrets OPENAI_API_KEY
    fi

    if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        cv_detect_secrets ANTHROPIC_API_KEY
    fi

    # ========================================================================
    # Boolean Configuration
    # ========================================================================

    # Debug mode
    if [ -n "${DEBUG:-}" ]; then
        cv_validate_boolean DEBUG
    fi

    # SSL/TLS settings
    if [ -n "${FORCE_SSL:-}" ]; then
        cv_validate_boolean FORCE_SSL
    fi

    # ========================================================================
    # Environment-Specific Validation
    # ========================================================================

    # Production-specific checks
    if [ "${NODE_ENV:-development}" = "production" ]; then
        cv_info "Production environment detected - applying strict validation"

        # Require SESSION_SECRET in production
        cv_require_var SESSION_SECRET \
            "Session secret for production" \
            "Generate: openssl rand -hex 32"

        # Ensure DEBUG is not enabled
        if [ "${DEBUG:-false}" = "true" ]; then
            cv_error "DEBUG mode enabled in production"
            cv_error "  Fix: Set DEBUG=false in production environment"
        fi

        # Ensure FORCE_SSL is enabled
        if [ "${FORCE_SSL:-false}" != "true" ]; then
            cv_warning "FORCE_SSL not enabled in production"
            cv_warning "  Recommendation: Set FORCE_SSL=true for security"
        fi
    fi

    # ========================================================================
    # Feature Flag Validation
    # ========================================================================

    # If feature flags are enabled, validate their configuration
    if [ "${ENABLE_FEATURE_UPLOADS:-false}" = "true" ]; then
        cv_require_var UPLOAD_DIR \
            "Upload directory for file uploads feature" \
            "Set UPLOAD_DIR to the directory where uploaded files will be stored"

        cv_validate_path UPLOAD_DIR true true
    fi

    # ========================================================================
    # Resource Limits
    # ========================================================================

    # Validate memory limit if set
    if [ -n "${MAX_MEMORY_MB:-}" ]; then
        if [[ ! "${MAX_MEMORY_MB}" =~ ^[0-9]+$ ]]; then
            cv_error "MAX_MEMORY_MB must be numeric"
            cv_error "  Value: ${MAX_MEMORY_MB}"
        elif [ "${MAX_MEMORY_MB}" -lt 256 ]; then
            cv_warning "MAX_MEMORY_MB is very low: ${MAX_MEMORY_MB}MB"
            cv_warning "  Recommendation: Use at least 512MB for web applications"
        fi
    fi

    # ========================================================================
    # Email Configuration
    # ========================================================================

    # If email is configured, validate settings
    if [ -n "${SMTP_HOST:-}" ]; then
        cv_require_var SMTP_PORT "SMTP port" "Set SMTP_PORT (usually 587 or 465)"
        cv_require_var SMTP_FROM "From email address" "Set SMTP_FROM to sender email"

        cv_validate_port SMTP_PORT
        cv_validate_email SMTP_FROM
    fi

    # Admin email
    if [ -n "${ADMIN_EMAIL:-}" ]; then
        cv_validate_email ADMIN_EMAIL
    fi

    cv_success "Web application validation complete"
}
