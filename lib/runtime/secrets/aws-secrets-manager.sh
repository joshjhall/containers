#!/bin/bash
# AWS Secrets Manager Integration for Container Runtime
#
# Description:
#   Provides integration with AWS Secrets Manager for secure secret management.
#   Supports IAM authentication and automatic secret injection into environment
#   variables.
#
# Environment Variables:
#   AWS_SECRETS_ENABLED    - Enable AWS Secrets Manager (true/false, default: false)
#   AWS_SECRET_NAME        - Name or ARN of secret in Secrets Manager (required)
#   AWS_REGION             - AWS region (default: from AWS CLI config or us-east-1)
#   AWS_SECRET_PREFIX      - Prefix for exported env vars (default: empty)
#   AWS_SECRET_VERSION_ID  - Specific version ID (optional, defaults to latest)
#   AWS_SECRET_VERSION_STAGE - Version stage (optional, defaults to AWSCURRENT)
#
# Authentication:
#   Uses standard AWS authentication chain:
#   1. Environment variables (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY)
#   2. AWS CLI config files (~/.aws/credentials, ~/.aws/config)
#   3. IAM instance profile (EC2)
#   4. ECS task role (ECS)
#   5. EKS service account (IRSA - IAM Roles for Service Accounts)
#
# Usage:
#   source /opt/container-runtime/secrets/aws-secrets-manager.sh
#   load_secrets_from_aws
#
# Exit Codes:
#   0 - Success (secrets loaded or AWS Secrets disabled)
#   1 - Configuration error
#   2 - Authentication error
#   3 - Secret retrieval error

set -euo pipefail

# Source shared logging and helpers
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ============================================================================
# Secret Retrieval Functions
# ============================================================================

# Load secrets from AWS Secrets Manager and export as environment variables
load_secrets_from_aws() {
    # Check if AWS Secrets Manager integration is enabled
    if [ "${AWS_SECRETS_ENABLED:-false}" != "true" ]; then
        log_info "AWS Secrets Manager integration disabled (AWS_SECRETS_ENABLED != true)"
        return 0
    fi

    # Validate required configuration
    if [ -z "${AWS_SECRET_NAME:-}" ]; then
        log_error "AWS_SECRET_NAME must be set when AWS_SECRETS_ENABLED=true"
        return 1
    fi

    # Check if AWS CLI is available
    if ! command -v aws > /dev/null 2>&1; then
        log_error "AWS CLI not found. Install AWS CLI to use Secrets Manager integration."
        return 1
    fi

    # Check if jq is available (needed for JSON parsing)
    if ! command -v jq > /dev/null 2>&1; then
        log_error "jq not found. Install jq to use Secrets Manager integration."
        return 1
    fi

    # Set region (use provided, or fallback to AWS CLI default, or us-east-1)
    local region="${AWS_REGION:-}"
    if [ -z "$region" ]; then
        region=$(aws configure get region 2>/dev/null || echo "us-east-1")
    fi
    export AWS_REGION="$region"

    log_info "Retrieving secret from AWS Secrets Manager: $AWS_SECRET_NAME (region: $region)"

    # Build AWS CLI command
    local aws_cmd="aws secretsmanager get-secret-value --secret-id $AWS_SECRET_NAME --region $region"

    # Add version parameters if specified
    if [ -n "${AWS_SECRET_VERSION_ID:-}" ]; then
        aws_cmd="$aws_cmd --version-id $AWS_SECRET_VERSION_ID"
    elif [ -n "${AWS_SECRET_VERSION_STAGE:-}" ]; then
        aws_cmd="$aws_cmd --version-stage $AWS_SECRET_VERSION_STAGE"
    fi

    # Retrieve secret from AWS Secrets Manager
    local secret_response
    secret_response=$($aws_cmd --output json 2>&1) || {
        log_error "Failed to retrieve secret from AWS Secrets Manager: $secret_response"

        # Check for common authentication errors
        if echo "$secret_response" | grep -q "UnrecognizedClientException\|InvalidClientTokenId\|AccessDenied"; then
            log_error "Authentication failed. Check AWS credentials and IAM permissions."
            return 2
        fi

        return 3
    }

    # Extract secret string
    local secret_string
    secret_string=$(echo "$secret_response" | jq -r '.SecretString // empty')

    if [ -z "$secret_string" ]; then
        # Try binary secret (base64 encoded)
        local secret_binary
        secret_binary=$(echo "$secret_response" | jq -r '.SecretBinary // empty')

        if [ -n "$secret_binary" ]; then
            secret_string=$(echo "$secret_binary" | base64 -d)
        else
            log_error "No secret data found in AWS Secrets Manager response"
            return 3
        fi
    fi

    # Parse secret string and export as environment variables
    local prefix="${AWS_SECRET_PREFIX:-}"
    local count=0

    # Try to parse as JSON first
    if echo "$secret_string" | jq -e . > /dev/null 2>&1; then
        # Secret is JSON - export each key-value pair
        while IFS='=' read -r key value; do
            if [ -n "$key" ] && [ -n "$value" ]; then
                local env_var="${prefix}${key}"
                export "${env_var}=${value}"
                count=$((count + 1))
                log_info "Loaded secret: $env_var"
            fi
        done < <(echo "$secret_string" | jq -r 'to_entries[] | "\(.key)=\(.value)"')
    else
        # Secret is plain text - export as single variable
        local env_var="${prefix}SECRET"
        if [ -n "${AWS_SECRET_ENV_VAR:-}" ]; then
            env_var="${AWS_SECRET_ENV_VAR}"
        fi

        export "${env_var}=${secret_string}"
        count=1
        log_info "Loaded secret: $env_var (plain text)"
    fi

    log_info "Successfully loaded $count secret(s) from AWS Secrets Manager"
    return 0
}

# ============================================================================
# AWS Secrets Manager Health Check
# ============================================================================

# Check if AWS Secrets Manager is accessible
aws_secrets_health_check() {
    if [ "${AWS_SECRETS_ENABLED:-false}" != "true" ]; then
        return 0
    fi

    if [ -z "${AWS_SECRET_NAME:-}" ]; then
        log_warning "AWS Secrets Manager enabled but AWS_SECRET_NAME not set"
        return 1
    fi

    log_info "Checking AWS Secrets Manager access"

    if ! command -v aws > /dev/null 2>&1; then
        log_warning "AWS CLI not found"
        return 1
    fi

    # Try to get caller identity to verify authentication
    if aws sts get-caller-identity > /dev/null 2>&1; then
        log_info "AWS authentication successful"
        return 0
    else
        log_warning "AWS authentication check failed"
        return 1
    fi
}

# ============================================================================
# Secret Rotation Support
# ============================================================================

# Check if secret has been rotated (newer version available)
check_secret_rotation() {
    if [ "${AWS_SECRETS_ENABLED:-false}" != "true" ]; then
        return 0
    fi

    if [ -z "${AWS_SECRET_NAME:-}" ]; then
        return 1
    fi

    local region="${AWS_REGION:-us-east-1}"

    log_info "Checking for secret rotation: $AWS_SECRET_NAME"

    # Get secret metadata
    local metadata
    metadata=$(aws secretsmanager describe-secret \
        --secret-id "$AWS_SECRET_NAME" \
        --region "$region" \
        --output json 2>&1) || {
        log_warning "Failed to check secret rotation: $metadata"
        return 1
    }

    # Check if rotation is enabled
    local rotation_enabled
    rotation_enabled=$(echo "$metadata" | jq -r '.RotationEnabled // false')

    if [ "$rotation_enabled" = "true" ]; then
        log_info "Secret rotation is enabled for $AWS_SECRET_NAME"

        # Get last rotation date
        local last_rotated
        last_rotated=$(echo "$metadata" | jq -r '.LastRotatedDate // "never"')
        log_info "Last rotated: $last_rotated"
    else
        log_info "Secret rotation is not enabled for $AWS_SECRET_NAME"
    fi

    return 0
}
