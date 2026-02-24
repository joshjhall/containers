#!/bin/bash
# Azure Key Vault Integration for Container Runtime
#
# Description:
#   Provides integration with Azure Key Vault for secure secret management.
#   Supports managed identity and service principal authentication with automatic
#   secret injection into environment variables.
#
# Environment Variables:
#   AZURE_KEYVAULT_ENABLED     - Enable Azure Key Vault (true/false, default: false)
#   AZURE_KEYVAULT_NAME        - Name of Azure Key Vault (required)
#   AZURE_KEYVAULT_URL         - Full URL of Key Vault (optional, constructed from name)
#   AZURE_SECRET_PREFIX        - Prefix for exported env vars (default: empty)
#   AZURE_SECRET_NAMES         - Comma-separated list of secret names to retrieve (optional, all if not set)
#   AZURE_TENANT_ID            - Azure AD tenant ID (for service principal auth)
#   AZURE_CLIENT_ID            - Azure AD client ID (for service principal auth)
#   AZURE_CLIENT_SECRET        - Azure AD client secret (for service principal auth)
#
# Authentication:
#   Uses standard Azure authentication chain:
#   1. Environment variables (service principal)
#   2. Managed Identity (System-assigned or User-assigned)
#   3. Azure CLI authentication
#
# Usage:
#   source /opt/container-runtime/secrets/azure-keyvault.sh
#   load_secrets_from_azure
#
# Exit Codes:
#   0 - Success (secrets loaded or Azure Key Vault disabled)
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

# Check Azure authentication
azure_check_authentication() {
    log_info "Checking Azure authentication"

    # Try to get current account to verify authentication
    if az account show > /dev/null 2>&1; then
        local account_name
        account_name=$(az account show --query name -o tsv 2>/dev/null || echo "unknown")
        log_info "Authenticated as: $account_name"
        return 0
    else
        log_error "Azure authentication failed. Configure service principal or managed identity."
        return 2
    fi
}

# Login with service principal if credentials are provided
azure_login_service_principal() {
    if [ -n "${AZURE_TENANT_ID:-}" ] && [ -n "${AZURE_CLIENT_ID:-}" ] && [ -n "${AZURE_CLIENT_SECRET:-}" ]; then
        log_info "Authenticating with Azure service principal"

        if az login --service-principal \
            --tenant "$AZURE_TENANT_ID" \
            --username "$AZURE_CLIENT_ID" \
            --password "$AZURE_CLIENT_SECRET" \
            --output none 2>&1; then
            log_info "Successfully authenticated with service principal"
            return 0
        else
            log_error "Service principal authentication failed"
            return 2
        fi
    fi

    return 1  # Credentials not provided
}

# ============================================================================
# Secret Retrieval Functions
# ============================================================================

# Load secrets from Azure Key Vault and export as environment variables
load_secrets_from_azure() {
    # Check if Azure Key Vault integration is enabled
    if [ "${AZURE_KEYVAULT_ENABLED:-false}" != "true" ]; then
        log_info "Azure Key Vault integration disabled (AZURE_KEYVAULT_ENABLED != true)"
        return 0
    fi

    # Validate required configuration
    if [ -z "${AZURE_KEYVAULT_NAME:-}" ] && [ -z "${AZURE_KEYVAULT_URL:-}" ]; then
        log_error "Either AZURE_KEYVAULT_NAME or AZURE_KEYVAULT_URL must be set when AZURE_KEYVAULT_ENABLED=true"
        return 1
    fi

    # Check if Azure CLI is available
    if ! command -v az > /dev/null 2>&1; then
        log_error "Azure CLI not found. Install Azure CLI to use Key Vault integration."
        return 1
    fi

    # Check if jq is available (needed for JSON parsing)
    if ! command -v jq > /dev/null 2>&1; then
        log_error "jq not found. Install jq to use Key Vault integration."
        return 1
    fi

    # Construct vault URL if not provided
    local vault_url="${AZURE_KEYVAULT_URL:-}"
    if [ -z "$vault_url" ]; then
        vault_url="https://${AZURE_KEYVAULT_NAME}.vault.azure.net"
    fi

    # Authenticate (try service principal first, then rely on managed identity/CLI)
    azure_login_service_principal || true

    # Verify authentication
    azure_check_authentication || return 2

    log_info "Retrieving secrets from Azure Key Vault: $vault_url"

    # Determine which secrets to retrieve
    local secret_names=()
    if [ -n "${AZURE_SECRET_NAMES:-}" ]; then
        # Specific secrets requested
        IFS=',' read -ra secret_names <<< "$AZURE_SECRET_NAMES"
    else
        # Retrieve all secrets
        log_info "Retrieving list of all secrets from Key Vault"
        local secrets_list
        secrets_list=$(az keyvault secret list \
            --vault-name "${AZURE_KEYVAULT_NAME}" \
            --query '[].name' \
            --output json 2>&1) || {
            log_error "Failed to list secrets from Key Vault: $secrets_list"
            return 3
        }

        # Parse secret names from JSON array
        mapfile -t secret_names < <(echo "$secrets_list" | jq -r '.[]')
    fi

    # Load each secret
    local prefix="${AZURE_SECRET_PREFIX:-}"
    local count=0

    for secret_name in "${secret_names[@]}"; do
        if [ -z "$secret_name" ]; then
            continue
        fi

        log_info "Retrieving secret: $secret_name"

        # Get secret value
        local secret_value
        secret_value=$(az keyvault secret show \
            --vault-name "${AZURE_KEYVAULT_NAME}" \
            --name "$secret_name" \
            --query value \
            --output tsv 2>&1) || {
            log_warning "Failed to retrieve secret '$secret_name': $secret_value"
            continue
        }

        if [ -z "$secret_value" ]; then
            log_warning "Secret '$secret_name' is empty, skipping"
            continue
        fi

        # Convert secret name to valid environment variable name
        # Azure Key Vault allows hyphens, but env vars use underscores
        local env_var_name="${prefix}${secret_name//-/_}"
        env_var_name="${env_var_name^^}"  # Convert to uppercase

        export "${env_var_name}=${secret_value}"
        count=$((count + 1))
        log_info "Loaded secret: $env_var_name"
    done

    log_info "Successfully loaded $count secret(s) from Azure Key Vault"
    return 0
}

# ============================================================================
# Azure Key Vault Health Check
# ============================================================================

# Check if Azure Key Vault is accessible
azure_keyvault_health_check() {
    if [ "${AZURE_KEYVAULT_ENABLED:-false}" != "true" ]; then
        return 0
    fi

    if [ -z "${AZURE_KEYVAULT_NAME:-}" ] && [ -z "${AZURE_KEYVAULT_URL:-}" ]; then
        log_warning "Azure Key Vault enabled but AZURE_KEYVAULT_NAME not set"
        return 1
    fi

    log_info "Checking Azure Key Vault access"

    if ! command -v az > /dev/null 2>&1; then
        log_warning "Azure CLI not found"
        return 1
    fi

    # Check if we can access the Key Vault
    if az keyvault show --name "${AZURE_KEYVAULT_NAME}" --output none 2>&1; then
        log_info "Azure Key Vault is accessible"
        return 0
    else
        log_warning "Azure Key Vault access check failed"
        return 1
    fi
}

# ============================================================================
# Certificate Support
# ============================================================================

# Load certificate from Azure Key Vault
load_certificate_from_azure() {
    local cert_name="$1"
    local output_path="$2"

    if [ -z "$cert_name" ] || [ -z "$output_path" ]; then
        log_error "Usage: load_certificate_from_azure <cert-name> <output-path>"
        return 1
    fi

    if [ "${AZURE_KEYVAULT_ENABLED:-false}" != "true" ]; then
        log_error "Azure Key Vault is not enabled"
        return 1
    fi

    log_info "Retrieving certificate: $cert_name"

    # Download certificate in PEM format
    az keyvault certificate download \
        --vault-name "${AZURE_KEYVAULT_NAME}" \
        --name "$cert_name" \
        --file "$output_path" \
        --encoding PEM || {
        log_error "Failed to retrieve certificate '$cert_name'"
        return 3
    }

    log_info "Certificate saved to: $output_path"
    return 0
}
