#!/bin/bash
# 1Password Integration for Container Runtime
#
# Description:
#   Enhanced 1Password integration for secure secret management.
#   Supports both Connect Server and CLI-based secret retrieval with automatic
#   environment variable injection.
#
# Environment Variables:
#   OP_ENABLED                 - Enable 1Password integration (true/false, default: false)
#   OP_CONNECT_HOST            - 1Password Connect server URL (for Connect API)
#   OP_CONNECT_TOKEN           - 1Password Connect access token (for Connect API)
#   OP_SERVICE_ACCOUNT_TOKEN   - 1Password service account token (for CLI)
#   OP_VAULT                   - Vault name or ID to use (optional, uses default if not set)
#   OP_SECRET_PREFIX           - Prefix for exported env vars (default: empty)
#   OP_ITEM_NAMES              - Comma-separated list of item names to retrieve (optional)
#   OP_SECRET_REFERENCES       - Comma-separated secret references (e.g., "op://vault/item/field")
#
# Authentication Methods:
#   1. Connect Server: OP_CONNECT_HOST + OP_CONNECT_TOKEN
#   2. Service Account: OP_SERVICE_ACCOUNT_TOKEN
#   3. CLI Session: Requires interactive `op signin`
#
# Usage:
#   source /opt/container-runtime/secrets/1password-integration.sh
#   load_secrets_from_1password
#
# Exit Codes:
#   0 - Success (secrets loaded or 1Password disabled)
#   1 - Configuration error
#   2 - Authentication error
#   3 - Secret retrieval error

set -euo pipefail

# Source shared logging and helpers
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ============================================================================
# 1Password Connect Server Functions
# ============================================================================

# Load secrets from 1Password Connect Server
op_connect_load_secrets() {
    if [ -z "${OP_CONNECT_HOST:-}" ] || [ -z "${OP_CONNECT_TOKEN:-}" ]; then
        return 1  # Connect not configured
    fi

    log_info "Using 1Password Connect Server at $OP_CONNECT_HOST"

    # Check if curl is available
    if ! command -v curl > /dev/null 2>&1; then
        log_error "curl not found. Install curl to use 1Password Connect."
        return 1
    fi

    # Check if jq is available
    if ! command -v jq > /dev/null 2>&1; then
        log_error "jq not found. Install jq to use 1Password Connect."
        return 1
    fi

    # Test Connect server connectivity
    local health_check
    health_check=$(curl -s -w "%{http_code}" -o /dev/null \
        "${OP_CONNECT_HOST}/health" 2>&1) || {
        log_error "Failed to connect to 1Password Connect server"
        return 2
    }

    if [ "$health_check" != "200" ]; then
        log_error "1Password Connect server health check failed (HTTP $health_check)"
        return 2
    fi

    # Get vault ID if vault name is provided
    local vault_id="${OP_VAULT:-}"
    if [ -n "$vault_id" ] && [[ ! "$vault_id" =~ ^[a-zA-Z0-9]{26}$ ]]; then
        # Vault name provided, need to lookup ID
        log_info "Looking up vault ID for: $vault_id"

        local vaults_response
        vaults_response=$(curl -s -w '\n%{http_code}' \
            -H "Authorization: Bearer ${OP_CONNECT_TOKEN}" \
            "${OP_CONNECT_HOST}/v1/vaults" 2>/dev/null) || {
            log_error "Failed to list vaults from Connect server"
            return 3
        }

        local vaults_http_code="${vaults_response##*$'\n'}"
        local vaults="${vaults_response%$'\n'*}"

        if [[ "$vaults_http_code" -lt 200 || "$vaults_http_code" -ge 300 ]]; then
            log_error "Failed to list vaults (HTTP $vaults_http_code)"
            return 3
        fi

        vault_id=$(echo "$vaults" | jq -r --arg name "$OP_VAULT" \
            '.[] | select(.name == $name) | .id' | head -n 1)

        if [ -z "$vault_id" ]; then
            log_error "Vault '$OP_VAULT' not found"
            return 3
        fi

        log_info "Found vault ID: $vault_id"
    fi

    # Load secrets from specific items if provided
    if [ -n "${OP_ITEM_NAMES:-}" ]; then
        local prefix="${OP_SECRET_PREFIX:-}"
        local count=0

        IFS=',' read -ra item_names <<< "$OP_ITEM_NAMES"
        for item_name in "${item_names[@]}"; do
            if [ -z "$item_name" ]; then
                continue
            fi

            log_info "Retrieving item: $item_name"

            # Get item from Connect API (URL-encode item name to prevent injection)
            local item
            local api_url="${OP_CONNECT_HOST}/v1/vaults/${vault_id}/items"
            local encoded_name
            encoded_name=$(url_encode "$item_name")
            local item_response
            item_response=$(curl -s -w '\n%{http_code}' \
                -H "Authorization: Bearer ${OP_CONNECT_TOKEN}" \
                "${api_url}?filter=title%20eq%20%22${encoded_name}%22" 2>/dev/null) || {
                log_warning "Failed to retrieve item '$item_name'"
                continue
            }

            local item_http_code="${item_response##*$'\n'}"
            item="${item_response%$'\n'*}"

            if [[ "$item_http_code" -lt 200 || "$item_http_code" -ge 300 ]]; then
                log_warning "Failed to retrieve item '$item_name' (HTTP $item_http_code)"
                continue
            fi

            # Extract first matching item
            local item_id
            item_id=$(echo "$item" | jq -r '.[0].id // empty')

            if [ -z "$item_id" ]; then
                log_warning "Item '$item_name' not found"
                continue
            fi

            # Get full item details
            local item_details
            item_details=$(curl -s \
                -H "Authorization: Bearer ${OP_CONNECT_TOKEN}" \
                "${OP_CONNECT_HOST}/v1/vaults/${vault_id}/items/${item_id}" 2>&1) || {
                log_warning "Failed to retrieve item details for '$item_name'"
                continue
            }

            # Extract fields and export as environment variables
            while IFS='=' read -r field_label field_value; do
                if [ -n "$field_label" ] && [ -n "$field_value" ]; then
                    local env_var
                    env_var=$(normalize_env_var_name "$prefix" "$field_label")

                    export "${env_var}=${field_value}"
                    count=$((count + 1))
                    log_info "Loaded secret: $env_var"
                fi
            done < <(echo "$item_details" | jq -r '.fields[] | select(.value != null) | "\(.label)=\(.value)"')
        done

        log_info "Successfully loaded $count secret(s) from 1Password Connect"
        return 0
    fi

    log_info "No specific items requested, use OP_ITEM_NAMES to specify items"
    return 0
}

# ============================================================================
# 1Password CLI Functions
# ============================================================================

# Load secrets using 1Password CLI
op_cli_load_secrets() {
    # Check if op CLI is available
    if ! command -v op > /dev/null 2>&1; then
        log_error "1Password CLI not found. Install 'op' to use 1Password integration."
        return 1
    fi

    # Authenticate with service account token if provided
    if [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
        log_info "Using 1Password service account authentication"
        export OP_SERVICE_ACCOUNT_TOKEN
    else
        # Check if already signed in
        if ! op account get > /dev/null 2>&1; then
            log_error "Not authenticated with 1Password CLI. Set OP_SERVICE_ACCOUNT_TOKEN or run 'op signin'"
            return 2
        fi
    fi

    local prefix="${OP_SECRET_PREFIX:-}"
    local count=0

    # Load secrets using secret references if provided
    if [ -n "${OP_SECRET_REFERENCES:-}" ]; then
        log_info "Loading secrets using secret references"

        IFS=',' read -ra references <<< "$OP_SECRET_REFERENCES"
        for ref in "${references[@]}"; do
            if [ -z "$ref" ]; then
                continue
            fi

            log_info "Loading secret reference: $ref"

            # Extract value using op read
            local value
            value=$(op read "$ref" 2>/dev/null) || {
                log_warning "Failed to read secret reference '$ref'"
                continue
            }

            # Extract field name from reference (op://vault/item/field)
            local field_name
            field_name=$(echo "$ref" | awk -F'/' '{print $NF}')
            field_name="${field_name// /_}"
            field_name="${field_name//[^a-zA-Z0-9_]/}"
            field_name="${field_name^^}"

            local env_var="${prefix}${field_name}"
            export "${env_var}=${value}"
            count=$((count + 1))
            log_info "Loaded secret: $env_var"
        done
    fi

    # Load secrets from specific items if provided
    if [ -n "${OP_ITEM_NAMES:-}" ]; then
        log_info "Loading secrets from items: $OP_ITEM_NAMES"

        IFS=',' read -ra item_names <<< "$OP_ITEM_NAMES"
        for item_name in "${item_names[@]}"; do
            if [ -z "$item_name" ]; then
                continue
            fi

            log_info "Retrieving item: $item_name"

            # Get item in JSON format
            local item_args=("item" "get" "$item_name" "--format=json")
            if [ -n "${OP_VAULT:-}" ]; then
                item_args+=("--vault=$OP_VAULT")
            fi

            local item_json
            item_json=$(op "${item_args[@]}" 2>/dev/null) || {
                log_warning "Failed to retrieve item '$item_name'"
                continue
            }

            # Extract fields and export as environment variables
            if command -v jq > /dev/null 2>&1; then
                while IFS='=' read -r field_label field_value; do
                    if [ -n "$field_label" ] && [ -n "$field_value" ]; then
                        local env_var
                        env_var=$(normalize_env_var_name "$prefix" "$field_label")

                        export "${env_var}=${field_value}"
                        count=$((count + 1))
                        log_info "Loaded secret: $env_var"
                    fi
                done < <(echo "$item_json" | jq -r '.fields[]? | select(.value != null and .value != "") | "\(.label)=\(.value)"')
            else
                log_warning "jq not found, cannot parse item fields"
            fi
        done
    fi

    log_info "Successfully loaded $count secret(s) from 1Password CLI"
    return 0
}

# ============================================================================
# Main Secret Loading Function
# ============================================================================

# Load secrets from 1Password (tries Connect first, then CLI)
load_secrets_from_1password() {
    # Check if 1Password integration is enabled
    if [ "${OP_ENABLED:-false}" != "true" ]; then
        log_info "1Password integration disabled (OP_ENABLED != true)"
        return 0
    fi

    log_info "Loading secrets from 1Password"

    # Try Connect Server first
    if op_connect_load_secrets 2>/dev/null; then
        return 0
    fi

    # Fall back to CLI
    if op_cli_load_secrets; then
        return 0
    fi

    log_error "Failed to load secrets from 1Password using all available methods"
    return 3
}

# ============================================================================
# Health Check
# ============================================================================

# Check if 1Password is accessible
op_health_check() {
    if [ "${OP_ENABLED:-false}" != "true" ]; then
        return 0
    fi

    log_info "Checking 1Password access"

    # Check Connect Server
    if [ -n "${OP_CONNECT_HOST:-}" ] && [ -n "${OP_CONNECT_TOKEN:-}" ]; then
        if command -v curl > /dev/null 2>&1; then
            local health
            health=$(curl -s -w "%{http_code}" -o /dev/null \
                "${OP_CONNECT_HOST}/health" 2>&1 || echo "000")

            if [ "$health" = "200" ]; then
                log_info "1Password Connect server is accessible"
                return 0
            fi
        fi
    fi

    # Check CLI
    if command -v op > /dev/null 2>&1; then
        if op account get > /dev/null 2>&1; then
            log_info "1Password CLI is authenticated"
            return 0
        fi
    fi

    log_warning "1Password is not accessible"
    return 1
}
