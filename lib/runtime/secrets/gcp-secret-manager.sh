#!/bin/bash
# GCP Secret Manager Integration for Container Runtime
#
# Description:
#   Provides integration with Google Cloud Secret Manager for secure secret management.
#   Supports Workload Identity (GKE), service account authentication, and ADC.
#
# Environment Variables:
#   GCP_SECRETS_ENABLED        - Enable GCP Secret Manager (true/false, default: false)
#   GCP_PROJECT_ID             - GCP project ID (required, or uses gcloud default)
#   GCP_SECRET_PREFIX          - Prefix for exported env vars (default: empty)
#   GCP_SECRET_NAMES           - Comma-separated list of secret names (optional, all if not set)
#   GCP_SECRET_VERSION         - Secret version (default: "latest")
#   GCP_SERVICE_ACCOUNT_KEY    - Path to service account JSON key file (optional)
#
# Authentication:
#   Uses standard GCP authentication chain:
#   1. Service account key file (GCP_SERVICE_ACCOUNT_KEY)
#   2. Application Default Credentials (ADC)
#   3. Workload Identity (GKE)
#   4. Compute Engine metadata server
#   5. gcloud CLI authentication
#
# Usage:
#   source /opt/container-runtime/secrets/gcp-secret-manager.sh
#   load_secrets_from_gcp
#
# Exit Codes:
#   0 - Success (secrets loaded or GCP Secrets disabled)
#   1 - Configuration error
#   2 - Authentication error
#   3 - Secret retrieval error

set -euo pipefail

# Source shared logging and helpers
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ============================================================================
# Authentication Functions
# ============================================================================

# Authenticate with GCP using service account key if provided
gcp_authenticate() {
    # If service account key is provided, activate it
    if [ -n "${GCP_SERVICE_ACCOUNT_KEY:-}" ]; then
        if [ ! -f "$GCP_SERVICE_ACCOUNT_KEY" ]; then
            log_error "Service account key file not found: $GCP_SERVICE_ACCOUNT_KEY"
            return 2
        fi

        log_info "Authenticating with service account key: $GCP_SERVICE_ACCOUNT_KEY"
        if gcloud auth activate-service-account --key-file="$GCP_SERVICE_ACCOUNT_KEY" 2>&1; then
            log_info "Successfully authenticated with service account"
            return 0
        else
            log_error "Failed to authenticate with service account key"
            return 2
        fi
    fi

    # Otherwise, verify that some authentication is available
    log_info "Checking GCP authentication"
    if gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | command head -n 1 | command grep -q .; then
        local account
        account=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" | command head -n 1)
        log_info "Using active GCP account: $account"
        return 0
    else
        log_error "No active GCP authentication found. Configure service account, ADC, or Workload Identity."
        return 2
    fi
}

# Get or verify GCP project ID
gcp_get_project_id() {
    local project_id="${GCP_PROJECT_ID:-}"

    # If not provided, try to get from gcloud config
    if [ -z "$project_id" ]; then
        project_id=$(gcloud config get-value project 2>/dev/null || echo "")
    fi

    # If still not found, try metadata server (for GCE/GKE)
    if [ -z "$project_id" ] && command -v curl > /dev/null 2>&1; then
        project_id=$(curl -s -f -H "Metadata-Flavor: Google" \
            "http://metadata.google.internal/computeMetadata/v1/project/project-id" 2>/dev/null || echo "")
    fi

    if [ -z "$project_id" ]; then
        log_error "GCP project ID not found. Set GCP_PROJECT_ID or configure gcloud default project."
        return 1
    fi

    echo "$project_id"
    return 0
}

# ============================================================================
# Secret Retrieval Functions
# ============================================================================

# Load secrets from GCP Secret Manager
load_secrets_from_gcp() {
    # Check if GCP Secret Manager integration is enabled
    if [ "${GCP_SECRETS_ENABLED:-false}" != "true" ]; then
        log_info "GCP Secret Manager integration disabled (GCP_SECRETS_ENABLED != true)"
        return 0
    fi

    # Check if gcloud CLI is available
    if ! command -v gcloud > /dev/null 2>&1; then
        log_error "gcloud CLI not found. Install Google Cloud SDK or enable INCLUDE_GCLOUD=true"
        return 1
    fi

    # Authenticate
    gcp_authenticate || return 2

    # Get project ID
    local project_id
    project_id=$(gcp_get_project_id) || return 1
    log_info "Using GCP project: $project_id"

    # Set project for gcloud commands
    export CLOUDSDK_CORE_PROJECT="$project_id"

    local prefix="${GCP_SECRET_PREFIX:-}"
    local version="${GCP_SECRET_VERSION:-latest}"
    local count=0

    # Determine which secrets to retrieve
    local secret_names=()
    if [ -n "${GCP_SECRET_NAMES:-}" ]; then
        # Specific secrets requested
        IFS=',' read -ra secret_names <<< "$GCP_SECRET_NAMES"
    else
        # Retrieve all secrets in project
        log_info "Retrieving list of all secrets from project"
        local secrets_list
        secrets_list=$(gcloud secrets list --format="value(name)" 2>&1) || {
            log_error "Failed to list secrets: $secrets_list"
            return 3
        }

        # Parse secret names
        mapfile -t secret_names <<< "$secrets_list"
    fi

    # Load each secret
    for secret_name in "${secret_names[@]}"; do
        # Trim whitespace
        secret_name=$(echo "$secret_name" | xargs)

        if [ -z "$secret_name" ]; then
            continue
        fi

        log_info "Retrieving secret: $secret_name (version: $version)"

        # Get secret value
        local secret_value
        secret_value=$(gcloud secrets versions access "$version" \
            --secret="$secret_name" \
            --project="$project_id" 2>&1) || {
            log_warning "Failed to retrieve secret '$secret_name': $secret_value"
            continue
        }

        if [ -z "$secret_value" ]; then
            log_warning "Secret '$secret_name' is empty, skipping"
            continue
        fi

        # Convert secret name to valid environment variable name
        # Replace hyphens with underscores
        local env_var_name="${prefix}${secret_name//-/_}"
        env_var_name="${env_var_name^^}"  # Convert to uppercase

        export "${env_var_name}=${secret_value}"
        count=$((count + 1))
        log_info "Loaded secret: $env_var_name"
    done

    log_info "Successfully loaded $count secret(s) from GCP Secret Manager"
    return 0
}

# ============================================================================
# GCP Secret Manager Health Check
# ============================================================================

# Check if GCP Secret Manager is accessible
gcp_secrets_health_check() {
    if [ "${GCP_SECRETS_ENABLED:-false}" != "true" ]; then
        return 0
    fi

    log_info "Checking GCP Secret Manager access"

    if ! command -v gcloud > /dev/null 2>&1; then
        log_warning "gcloud CLI not found"
        return 1
    fi

    # Try to get project ID and list secrets
    local project_id
    if project_id=$(gcp_get_project_id 2>/dev/null); then
        if gcloud secrets list --project="$project_id" --limit=1 > /dev/null 2>&1; then
            log_info "GCP Secret Manager is accessible (project: $project_id)"
            return 0
        fi
    fi

    log_warning "GCP Secret Manager access check failed"
    return 1
}

# ============================================================================
# Secret Metadata Functions
# ============================================================================

# Get secret metadata
gcp_get_secret_metadata() {
    local secret_name="$1"

    if [ -z "$secret_name" ]; then
        log_error "Usage: gcp_get_secret_metadata <secret-name>"
        return 1
    fi

    if [ "${GCP_SECRETS_ENABLED:-false}" != "true" ]; then
        log_error "GCP Secret Manager is not enabled"
        return 1
    fi

    local project_id
    project_id=$(gcp_get_project_id) || return 1

    log_info "Retrieving metadata for secret: $secret_name"

    gcloud secrets describe "$secret_name" \
        --project="$project_id" \
        --format=json
}

# List all versions of a secret
gcp_list_secret_versions() {
    local secret_name="$1"

    if [ -z "$secret_name" ]; then
        log_error "Usage: gcp_list_secret_versions <secret-name>"
        return 1
    fi

    if [ "${GCP_SECRETS_ENABLED:-false}" != "true" ]; then
        log_error "GCP Secret Manager is not enabled"
        return 1
    fi

    local project_id
    project_id=$(gcp_get_project_id) || return 1

    log_info "Listing versions for secret: $secret_name"

    gcloud secrets versions list "$secret_name" \
        --project="$project_id" \
        --format="table(name,state,createTime)"
}
