#!/usr/bin/env bash
# API Service Validation Rules
#
# This example demonstrates configuration validation for an API service
# with multiple data sources, rate limiting, and authentication.
#
# Usage:
#   Set VALIDATE_CONFIG_RULES=/path/to/api-service-validation.sh

cv_custom_validations() {
    echo "Running API service configuration validation..."

    # ========================================================================
    # Required Variables
    # ========================================================================

    cv_require_var API_PORT \
        "API server port" \
        "Set API_PORT to the port number for the API server (e.g., 8080)"

    cv_require_var JWT_SECRET \
        "JWT token signing secret" \
        "Generate: openssl rand -base64 32"

    # ========================================================================
    # Database Configuration
    # ========================================================================

    # Primary database
    cv_require_var DATABASE_URL \
        "Primary database connection" \
        "Set DATABASE_URL to postgresql://user:pass@host:port/dbname"

    cv_validate_url DATABASE_URL "postgresql"

    # Read replica (optional)
    if [ -n "${DATABASE_READ_REPLICA_URL:-}" ]; then
        cv_validate_url DATABASE_READ_REPLICA_URL "postgresql"
    fi

    # ========================================================================
    # Cache Configuration
    # ========================================================================

    # Redis is required for rate limiting and caching
    cv_require_var REDIS_URL \
        "Redis connection for caching and rate limiting" \
        "Set REDIS_URL to redis://host:port/db"

    cv_validate_url REDIS_URL "redis"

    # ========================================================================
    # Port Configuration
    # ========================================================================

    cv_validate_port API_PORT

    if [ -n "${METRICS_PORT:-}" ]; then
        cv_validate_port METRICS_PORT

        # Ensure metrics port is different from API port
        if [ "${API_PORT}" = "${METRICS_PORT}" ]; then
            cv_error "API_PORT and METRICS_PORT cannot be the same"
            cv_error "  API_PORT: ${API_PORT}"
            cv_error "  METRICS_PORT: ${METRICS_PORT}"
        fi
    fi

    # ========================================================================
    # Rate Limiting Configuration
    # ========================================================================

    if [ -n "${RATE_LIMIT_MAX:-}" ]; then
        if [[ ! "${RATE_LIMIT_MAX}" =~ ^[0-9]+$ ]]; then
            cv_error "RATE_LIMIT_MAX must be numeric"
            cv_error "  Value: ${RATE_LIMIT_MAX}"
        fi
    fi

    if [ -n "${RATE_LIMIT_WINDOW_MS:-}" ]; then
        if [[ ! "${RATE_LIMIT_WINDOW_MS}" =~ ^[0-9]+$ ]]; then
            cv_error "RATE_LIMIT_WINDOW_MS must be numeric"
            cv_error "  Value: ${RATE_LIMIT_WINDOW_MS}"
        fi
    fi

    # ========================================================================
    # Authentication & Security
    # ========================================================================

    # JWT secret validation
    cv_detect_secrets JWT_SECRET

    # Check JWT secret length
    if [ -n "${JWT_SECRET:-}" ] && [ ${#JWT_SECRET} -lt 32 ]; then
        cv_warning "JWT_SECRET is too short (${#JWT_SECRET} characters)"
        cv_warning "  Recommendation: Use at least 32 characters for security"
    fi

    # API keys
    if [ -n "${ADMIN_API_KEY:-}" ]; then
        cv_detect_secrets ADMIN_API_KEY
    fi

    # ========================================================================
    # External Service Integration
    # ========================================================================

    # Payment provider
    if [ "${ENABLE_PAYMENTS:-false}" = "true" ]; then
        cv_require_var STRIPE_SECRET_KEY \
            "Stripe secret key for payment processing" \
            "Obtain from Stripe dashboard"

        cv_detect_secrets STRIPE_SECRET_KEY

        if [ -n "${STRIPE_WEBHOOK_SECRET:-}" ]; then
            cv_detect_secrets STRIPE_WEBHOOK_SECRET
        fi
    fi

    # Email service
    if [ "${ENABLE_EMAIL:-false}" = "true" ]; then
        cv_require_var SENDGRID_API_KEY \
            "SendGrid API key for email delivery" \
            "Obtain from SendGrid dashboard"

        cv_detect_secrets SENDGRID_API_KEY
    fi

    # ========================================================================
    # CORS Configuration
    # ========================================================================

    if [ -n "${CORS_ORIGIN:-}" ]; then
        # Check if CORS_ORIGIN is wildcard in production
        if [ "${ENVIRONMENT:-development}" = "production" ] && [ "${CORS_ORIGIN}" = "*" ]; then
            cv_error "CORS_ORIGIN cannot be '*' in production"
            cv_error "  Fix: Set CORS_ORIGIN to specific allowed origins"
        fi

        # Validate URL format if not wildcard
        if [ "${CORS_ORIGIN}" != "*" ]; then
            cv_validate_url CORS_ORIGIN "https"
        fi
    fi

    # ========================================================================
    # Logging Configuration
    # ========================================================================

    if [ -n "${LOG_LEVEL:-}" ]; then
        local valid_levels="debug|info|warn|error"
        if [[ ! "${LOG_LEVEL}" =~ ^($valid_levels)$ ]]; then
            cv_error "Invalid LOG_LEVEL: ${LOG_LEVEL}"
            cv_error "  Valid values: debug, info, warn, error"
        fi
    fi

    # ========================================================================
    # Performance Configuration
    # ========================================================================

    # Connection pool size
    if [ -n "${DB_POOL_SIZE:-}" ]; then
        if [[ ! "${DB_POOL_SIZE}" =~ ^[0-9]+$ ]]; then
            cv_error "DB_POOL_SIZE must be numeric"
            cv_error "  Value: ${DB_POOL_SIZE}"
        elif [ "${DB_POOL_SIZE}" -lt 5 ]; then
            cv_warning "DB_POOL_SIZE is very low: ${DB_POOL_SIZE}"
            cv_warning "  Recommendation: Use at least 10 for API services"
        fi
    fi

    # Request timeout
    if [ -n "${REQUEST_TIMEOUT_MS:-}" ]; then
        if [[ ! "${REQUEST_TIMEOUT_MS}" =~ ^[0-9]+$ ]]; then
            cv_error "REQUEST_TIMEOUT_MS must be numeric"
            cv_error "  Value: ${REQUEST_TIMEOUT_MS}"
        fi
    fi

    # ========================================================================
    # Environment-Specific Checks
    # ========================================================================

    if [ "${ENVIRONMENT:-development}" = "production" ]; then
        cv_info "Production environment - enforcing strict security policies"

        # Require HTTPS in production
        if [ "${FORCE_HTTPS:-false}" != "true" ]; then
            cv_error "FORCE_HTTPS must be enabled in production"
            cv_error "  Fix: Set FORCE_HTTPS=true"
        fi

        # Require rate limiting
        if [ -z "${RATE_LIMIT_MAX:-}" ]; then
            cv_warning "Rate limiting not configured in production"
            cv_warning "  Recommendation: Set RATE_LIMIT_MAX and RATE_LIMIT_WINDOW_MS"
        fi

        # Ensure monitoring is enabled
        if [ -z "${METRICS_PORT:-}" ]; then
            cv_warning "Metrics port not configured"
            cv_warning "  Recommendation: Enable metrics with METRICS_PORT for observability"
        fi
    fi

    cv_success "API service validation complete"
}
