#!/usr/bin/env bash
# Worker Service Validation Rules
#
# This example demonstrates configuration validation for a background worker
# that processes jobs from a queue.
#
# Usage:
#   Set VALIDATE_CONFIG_RULES=/path/to/worker-validation.sh

cv_custom_validations() {
    echo "Running worker service configuration validation..."

    # ========================================================================
    # Required Variables
    # ========================================================================

    cv_require_var REDIS_URL \
        "Redis connection for job queue" \
        "Set REDIS_URL to redis://host:port/db"

    cv_require_var WORKER_CONCURRENCY \
        "Number of concurrent workers" \
        "Set WORKER_CONCURRENCY to desired worker count (e.g., 4)"

    # ========================================================================
    # Queue Configuration
    # ========================================================================

    cv_validate_url REDIS_URL "redis"

    # Validate concurrency setting
    if [[ ! "${WORKER_CONCURRENCY}" =~ ^[0-9]+$ ]]; then
        cv_error "WORKER_CONCURRENCY must be numeric"
        cv_error "  Value: ${WORKER_CONCURRENCY}"
    elif [ "${WORKER_CONCURRENCY}" -lt 1 ]; then
        cv_error "WORKER_CONCURRENCY must be at least 1"
        cv_error "  Value: ${WORKER_CONCURRENCY}"
    elif [ "${WORKER_CONCURRENCY}" -gt 20 ]; then
        cv_warning "WORKER_CONCURRENCY is very high: ${WORKER_CONCURRENCY}"
        cv_warning "  This may cause resource exhaustion"
    fi

    # ========================================================================
    # Database Configuration (if needed)
    # ========================================================================

    if [ -n "${DATABASE_URL:-}" ]; then
        cv_validate_url DATABASE_URL "postgresql"
    fi

    # ========================================================================
    # Job Timeout Configuration
    # ========================================================================

    if [ -n "${JOB_TIMEOUT_SEC:-}" ]; then
        if [[ ! "${JOB_TIMEOUT_SEC}" =~ ^[0-9]+$ ]]; then
            cv_error "JOB_TIMEOUT_SEC must be numeric"
            cv_error "  Value: ${JOB_TIMEOUT_SEC}"
        fi
    else
        cv_warning "JOB_TIMEOUT_SEC not set - jobs may run indefinitely"
        cv_warning "  Recommendation: Set a reasonable timeout (e.g., 300 for 5 minutes)"
    fi

    # Retry configuration
    if [ -n "${MAX_RETRIES:-}" ]; then
        if [[ ! "${MAX_RETRIES}" =~ ^[0-9]+$ ]]; then
            cv_error "MAX_RETRIES must be numeric"
            cv_error "  Value: ${MAX_RETRIES}"
        fi
    fi

    # ========================================================================
    # Storage Configuration
    # ========================================================================

    # Temp directory for job processing
    if [ -n "${WORKER_TEMP_DIR:-}" ]; then
        cv_validate_path WORKER_TEMP_DIR true true
    fi

    # Output directory (if applicable)
    if [ -n "${OUTPUT_DIR:-}" ]; then
        cv_validate_path OUTPUT_DIR true true
    fi

    # ========================================================================
    # External Service Configuration
    # ========================================================================

    # S3 for file storage
    if [ "${USE_S3_STORAGE:-false}" = "true" ]; then
        cv_require_var AWS_S3_BUCKET \
            "S3 bucket for file storage" \
            "Set AWS_S3_BUCKET to your S3 bucket name"

        cv_require_var AWS_REGION \
            "AWS region" \
            "Set AWS_REGION (e.g., us-east-1)"

        # Detect plaintext AWS credentials (should use IAM roles instead)
        if [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
            cv_warning "AWS_ACCESS_KEY_ID detected"
            cv_warning "  Recommendation: Use IAM roles instead of access keys in production"
        fi

        if [ -n "${AWS_SECRET_ACCESS_KEY:-}" ]; then
            cv_detect_secrets AWS_SECRET_ACCESS_KEY
        fi
    fi

    # ========================================================================
    # Resource Limits
    # ========================================================================

    # Memory limit per worker
    if [ -n "${WORKER_MEMORY_LIMIT_MB:-}" ]; then
        if [[ ! "${WORKER_MEMORY_LIMIT_MB}" =~ ^[0-9]+$ ]]; then
            cv_error "WORKER_MEMORY_LIMIT_MB must be numeric"
            cv_error "  Value: ${WORKER_MEMORY_LIMIT_MB}"
        elif [ "${WORKER_MEMORY_LIMIT_MB}" -lt 128 ]; then
            cv_warning "WORKER_MEMORY_LIMIT_MB is very low: ${WORKER_MEMORY_LIMIT_MB}MB"
            cv_warning "  Workers may crash due to insufficient memory"
        fi
    fi

    # ========================================================================
    # Monitoring Configuration
    # ========================================================================

    if [ -n "${METRICS_PORT:-}" ]; then
        cv_validate_port METRICS_PORT
    else
        cv_warning "METRICS_PORT not configured"
        cv_warning "  Recommendation: Enable metrics for monitoring worker health"
    fi

    # ========================================================================
    # Queue Prioritization
    # ========================================================================

    # Validate queue priority levels
    if [ -n "${QUEUE_PRIORITIES:-}" ]; then
        # QUEUE_PRIORITIES should be comma-separated (e.g., "high,normal,low")
        IFS=',' read -ra PRIORITIES <<< "${QUEUE_PRIORITIES}"
        for priority in "${PRIORITIES[@]}"; do
            priority=$(echo "$priority" | xargs) # trim whitespace
            if [[ ! "$priority" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                cv_error "Invalid queue priority: $priority"
                cv_error "  Priorities must be alphanumeric with hyphens/underscores"
            fi
        done
    fi

    # ========================================================================
    # Graceful Shutdown Configuration
    # ========================================================================

    if [ -n "${SHUTDOWN_TIMEOUT_SEC:-}" ]; then
        if [[ ! "${SHUTDOWN_TIMEOUT_SEC}" =~ ^[0-9]+$ ]]; then
            cv_error "SHUTDOWN_TIMEOUT_SEC must be numeric"
            cv_error "  Value: ${SHUTDOWN_TIMEOUT_SEC}"
        fi
    else
        cv_info "SHUTDOWN_TIMEOUT_SEC not set - using default graceful shutdown"
    fi

    cv_success "Worker service validation complete"
}
