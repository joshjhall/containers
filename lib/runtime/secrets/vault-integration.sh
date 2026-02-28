#!/bin/bash
# HashiCorp Vault Integration for Container Runtime
#
# Description:
#   Provides integration with HashiCorp Vault for secure secret management.
#   Supports multiple authentication methods and automatic secret injection
#   into environment variables.
#
# Environment Variables:
#   VAULT_ENABLED          - Enable Vault integration (true/false, default: false)
#   VAULT_ADDR             - Vault server address (required)
#   VAULT_TOKEN            - Vault authentication token (token auth)
#   VAULT_ROLE_ID          - AppRole role ID (approle auth)
#   VAULT_SECRET_ID        - AppRole secret ID (approle auth)
#   VAULT_K8S_ROLE         - Kubernetes service account role (k8s auth)
#   VAULT_NAMESPACE        - Vault namespace (for Vault Enterprise)
#   VAULT_SECRET_PATH      - Path to secrets in Vault (e.g., secret/data/myapp)
#   VAULT_SECRET_PREFIX    - Prefix for exported env vars (default: empty)
#   VAULT_AUTH_METHOD      - Auth method: token, approle, kubernetes (default: token)
#
# Usage:
#   source /opt/container-runtime/secrets/vault-integration.sh
#   load_secrets_from_vault
#
# Exit Codes:
#   0 - Success (secrets loaded or Vault disabled)
#   1 - Configuration error
#   2 - Authentication error
#   3 - Secret retrieval error

set -euo pipefail

# Source shared logging and helpers
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ============================================================================
# Vault Authentication Functions
# ============================================================================

# Authenticate with Vault using token
vault_auth_token() {
    if [ -z "${VAULT_TOKEN:-}" ]; then
        log_error "VAULT_TOKEN not set for token authentication"
        return 2
    fi

    log_info "Authenticating to Vault using token authentication"
    export VAULT_TOKEN

    # Verify token is valid
    if ! vault token lookup > /dev/null 2>&1; then
        log_error "Vault token is invalid or expired"
        return 2
    fi

    log_info "Successfully authenticated to Vault with token"
    return 0
}

# Authenticate with Vault using AppRole
vault_auth_approle() {
    if [ -z "${VAULT_ROLE_ID:-}" ] || [ -z "${VAULT_SECRET_ID:-}" ]; then
        log_error "VAULT_ROLE_ID and VAULT_SECRET_ID must be set for approle authentication"
        return 2
    fi

    log_info "Authenticating to Vault using AppRole authentication"

    # Login with AppRole
    local response
    response=$(vault write -format=json auth/approle/login \
        role_id="${VAULT_ROLE_ID}" \
        secret_id="${VAULT_SECRET_ID}" 2>&1) || {
        log_error "AppRole authentication failed: $response"
        return 2
    }

    # Extract token from response
    VAULT_TOKEN=$(echo "$response" | jq -r '.auth.client_token')
    if [ -z "$VAULT_TOKEN" ] || [ "$VAULT_TOKEN" = "null" ]; then
        log_error "Failed to extract token from AppRole response"
        return 2
    fi

    export VAULT_TOKEN
    log_info "Successfully authenticated to Vault with AppRole"
    return 0
}

# Authenticate with Vault using Kubernetes service account
vault_auth_kubernetes() {
    if [ -z "${VAULT_K8S_ROLE:-}" ]; then
        log_error "VAULT_K8S_ROLE must be set for Kubernetes authentication"
        return 2
    fi

    local jwt_path="/var/run/secrets/kubernetes.io/serviceaccount/token"
    if [ ! -f "$jwt_path" ]; then
        log_error "Kubernetes service account token not found at $jwt_path"
        return 2
    fi

    log_info "Authenticating to Vault using Kubernetes authentication"

    # Read JWT token
    local jwt
    jwt=$(command cat "$jwt_path")

    # Login with Kubernetes auth
    local response
    response=$(vault write -format=json auth/kubernetes/login \
        role="${VAULT_K8S_ROLE}" \
        jwt="$jwt" 2>&1) || {
        log_error "Kubernetes authentication failed: $response"
        return 2
    }

    # Extract token from response
    VAULT_TOKEN=$(echo "$response" | jq -r '.auth.client_token')
    if [ -z "$VAULT_TOKEN" ] || [ "$VAULT_TOKEN" = "null" ]; then
        log_error "Failed to extract token from Kubernetes auth response"
        return 2
    fi

    export VAULT_TOKEN
    log_info "Successfully authenticated to Vault with Kubernetes"
    return 0
}

# ============================================================================
# Secret Retrieval Functions
# ============================================================================

# Load secrets from Vault and export as environment variables
load_secrets_from_vault() {
    # Check if Vault integration is enabled
    if [ "${VAULT_ENABLED:-false}" != "true" ]; then
        log_info "Vault integration disabled (VAULT_ENABLED != true)"
        return 0
    fi

    # Validate required configuration
    if [ -z "${VAULT_ADDR:-}" ]; then
        log_error "VAULT_ADDR must be set when VAULT_ENABLED=true"
        return 1
    fi

    if [ -z "${VAULT_SECRET_PATH:-}" ]; then
        log_error "VAULT_SECRET_PATH must be set when VAULT_ENABLED=true"
        return 1
    fi

    # Check if vault CLI is available
    if ! command -v vault > /dev/null 2>&1; then
        log_error "Vault CLI not found. Install HashiCorp Vault CLI to use Vault integration."
        return 1
    fi

    # Check if jq is available (needed for JSON parsing)
    if ! command -v jq > /dev/null 2>&1; then
        log_error "jq not found. Install jq to use Vault integration."
        return 1
    fi

    export VAULT_ADDR

    # Set namespace if provided (for Vault Enterprise)
    if [ -n "${VAULT_NAMESPACE:-}" ]; then
        export VAULT_NAMESPACE
        log_info "Using Vault namespace: $VAULT_NAMESPACE"
    fi

    # Authenticate based on configured method
    local auth_method="${VAULT_AUTH_METHOD:-token}"
    case "$auth_method" in
        token)
            vault_auth_token || return 2
            ;;
        approle)
            vault_auth_approle || return 2
            ;;
        kubernetes|k8s)
            vault_auth_kubernetes || return 2
            ;;
        *)
            log_error "Unknown VAULT_AUTH_METHOD: $auth_method (supported: token, approle, kubernetes)"
            return 1
            ;;
    esac

    # Retrieve secrets from Vault
    log_info "Retrieving secrets from Vault path: $VAULT_SECRET_PATH"

    local secrets_json
    secrets_json=$(vault kv get -format=json "$VAULT_SECRET_PATH" 2>&1) || {
        log_error "Failed to retrieve secrets from Vault: $secrets_json"
        return 3
    }

    # Extract secret data (handles both KV v1 and v2)
    local data_path=".data.data"
    if ! echo "$secrets_json" | jq -e "$data_path" > /dev/null 2>&1; then
        # Try KV v1 format
        data_path=".data"
        if ! echo "$secrets_json" | jq -e "$data_path" > /dev/null 2>&1; then
            log_error "Unable to parse secrets from Vault response"
            return 3
        fi
    fi

    # Export secrets as environment variables
    local prefix="${VAULT_SECRET_PREFIX:-}"
    local count=0

    while IFS='=' read -r key value; do
        if [ -n "$key" ] && [ -n "$value" ]; then
            local env_var="${prefix}${key}"
            export "${env_var}=${value}"
            count=$((count + 1))
            log_info "Loaded secret: $env_var"
        fi
    done < <(echo "$secrets_json" | jq -r "$data_path | to_entries[] | \"\(.key)=\(.value)\"")

    log_info "Successfully loaded $count secrets from Vault"
    return 0
}

# ============================================================================
# Vault Health Check
# ============================================================================

# Check if Vault is accessible and healthy
vault_health_check() {
    if [ "${VAULT_ENABLED:-false}" != "true" ]; then
        return 0
    fi

    if [ -z "${VAULT_ADDR:-}" ]; then
        log_warning "Vault enabled but VAULT_ADDR not set"
        return 1
    fi

    log_info "Checking Vault health at $VAULT_ADDR"

    if ! command -v vault > /dev/null 2>&1; then
        log_warning "Vault CLI not found"
        return 1
    fi

    if vault status > /dev/null 2>&1; then
        log_info "Vault is accessible and healthy"
        return 0
    else
        log_warning "Vault health check failed"
        return 1
    fi
}
