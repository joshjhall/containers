#!/bin/bash
# Universal Secret Loader for Container Runtime
#
# Description:
#   Orchestrates secret loading from multiple secret management providers.
#   Automatically detects and loads from enabled providers in priority order.
#
# Environment Variables:
#   SECRET_LOADER_ENABLED      - Enable secret loading (true/false, default: true)
#   SECRET_LOADER_PRIORITY     - Comma-separated list of providers in priority order
#                                (default: "docker,1password,vault,aws,azure,gcp")
#   SECRET_LOADER_FAIL_ON_ERROR - Exit if any provider fails (default: false)
#
# Supported Providers:
#   - docker     : Docker Secrets (Swarm/Compose)
#   - 1password  : 1Password Connect or CLI
#   - vault      : HashiCorp Vault
#   - aws        : AWS Secrets Manager
#   - azure      : Azure Key Vault
#   - gcp        : GCP Secret Manager
#
# Usage:
#   source /opt/container-runtime/secrets/load-secrets.sh
#   load_all_secrets
#
# Exit Codes:
#   0 - Success (secrets loaded or disabled)
#   1 - Configuration/initialization error
#   2 - One or more providers failed (with FAIL_ON_ERROR=true)

set -euo pipefail

# Source logging utilities if available
if [ -f "/tmp/build-scripts/base/logging.sh" ]; then
    # shellcheck source=/dev/null
    source "/tmp/build-scripts/base/logging.sh"
elif [ -f "/opt/container-runtime/base/logging.sh" ]; then
    # shellcheck source=/dev/null
    source "/opt/container-runtime/base/logging.sh"
else
    # Fallback logging functions
    log_info() { echo "[INFO] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_warning() { echo "[WARNING] $*" >&2; }
fi

# ============================================================================
# Secret Provider Registry
# ============================================================================

# Get the directory where secret integration scripts are located
get_secrets_dir() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    echo "$script_dir"
}

# Source a secret provider integration script
source_provider() {
    local provider="$1"
    local secrets_dir
    secrets_dir=$(get_secrets_dir)

    local script_mapping
    case "$provider" in
        1password|op)
            script_mapping="1password-integration.sh"
            ;;
        vault|hashicorp)
            script_mapping="vault-integration.sh"
            ;;
        aws|aws-secrets)
            script_mapping="aws-secrets-manager.sh"
            ;;
        azure|azure-keyvault)
            script_mapping="azure-keyvault.sh"
            ;;
        gcp|gcp-secrets|google)
            script_mapping="gcp-secret-manager.sh"
            ;;
        docker|docker-secrets)
            script_mapping="docker-secrets.sh"
            ;;
        *)
            log_warning "Unknown secret provider: $provider"
            return 1
            ;;
    esac

    local script_path="${secrets_dir}/${script_mapping}"
    if [ ! -f "$script_path" ]; then
        log_warning "Secret provider script not found: $script_path"
        return 1
    fi

    # shellcheck source=/dev/null
    source "$script_path"
    return 0
}

# ============================================================================
# Provider Loading Functions
# ============================================================================

# Load secrets from a single provider
load_provider_secrets() {
    local provider="$1"
    local function_name=""

    case "$provider" in
        1password|op)
            function_name="load_secrets_from_1password"
            ;;
        vault|hashicorp)
            function_name="load_secrets_from_vault"
            ;;
        aws|aws-secrets)
            function_name="load_secrets_from_aws"
            ;;
        azure|azure-keyvault)
            function_name="load_secrets_from_azure"
            ;;
        gcp|gcp-secrets|google)
            function_name="load_secrets_from_gcp"
            ;;
        docker|docker-secrets)
            function_name="load_secrets_from_docker"
            ;;
        *)
            log_warning "Unknown provider: $provider"
            return 1
            ;;
    esac

    # Check if function exists
    if ! command -v "$function_name" > /dev/null 2>&1; then
        log_warning "Provider function not loaded: $function_name"
        return 1
    fi

    # Call the provider's load function
    log_info "======================================================================"
    log_info "Loading secrets from provider: $provider"
    log_info "======================================================================"

    if "$function_name"; then
        log_info "Successfully loaded secrets from $provider"
        return 0
    else
        local exit_code=$?
        log_warning "Failed to load secrets from $provider (exit code: $exit_code)"
        return "$exit_code"
    fi
}

# ============================================================================
# Main Secret Loading Function
# ============================================================================

# Load secrets from all enabled providers
load_all_secrets() {
    # Check if secret loading is enabled
    if [ "${SECRET_LOADER_ENABLED:-true}" != "true" ]; then
        log_info "Secret loader disabled (SECRET_LOADER_ENABLED != true)"
        return 0
    fi

    log_info "========================================================================"
    log_info "Universal Secret Loader - Starting"
    log_info "========================================================================"
    echo ""

    # Get provider priority list
    local priority="${SECRET_LOADER_PRIORITY:-docker,1password,vault,aws,azure,gcp}"
    local fail_on_error="${SECRET_LOADER_FAIL_ON_ERROR:-false}"

    IFS=',' read -ra providers <<< "$priority"

    local total_providers=0
    local successful_providers=0
    local failed_providers=0

    # Source all provider scripts
    for provider in "${providers[@]}"; do
        if [ -n "$provider" ]; then
            source_provider "$provider" || true
        fi
    done

    # Load secrets from each provider
    for provider in "${providers[@]}"; do
        if [ -z "$provider" ]; then
            continue
        fi

        total_providers=$((total_providers + 1))

        if load_provider_secrets "$provider"; then
            successful_providers=$((successful_providers + 1))
            echo ""
        else
            failed_providers=$((failed_providers + 1))
            echo ""

            if [ "$fail_on_error" = "true" ]; then
                log_error "Secret loading failed for provider: $provider"
                log_error "Aborting secret loading due to SECRET_LOADER_FAIL_ON_ERROR=true"
                return 2
            fi
        fi
    done

    # Summary
    log_info "========================================================================"
    log_info "Universal Secret Loader - Summary"
    log_info "========================================================================"
    log_info "Total providers: $total_providers"
    log_info "Successful: $successful_providers"
    log_info "Failed: $failed_providers"
    log_info "========================================================================"
    echo ""

    if [ "$failed_providers" -gt 0 ] && [ "$fail_on_error" = "true" ]; then
        return 2
    fi

    return 0
}

# ============================================================================
# Health Check Functions
# ============================================================================

# Run health checks on all configured secret providers
check_all_providers_health() {
    log_info "Running health checks on secret providers"

    local providers=("docker" "1password" "vault" "aws" "azure" "gcp")
    local healthy=0
    local unhealthy=0

    for provider in "${providers[@]}"; do
        source_provider "$provider" || continue

        local health_function=""
        case "$provider" in
            docker)
                health_function="docker_secrets_health_check"
                ;;
            1password)
                health_function="op_health_check"
                ;;
            vault)
                health_function="vault_health_check"
                ;;
            aws)
                health_function="aws_secrets_health_check"
                ;;
            azure)
                health_function="azure_keyvault_health_check"
                ;;
            gcp)
                health_function="gcp_secrets_health_check"
                ;;
        esac

        if command -v "$health_function" > /dev/null 2>&1; then
            if "$health_function"; then
                healthy=$((healthy + 1))
            else
                unhealthy=$((unhealthy + 1))
            fi
        fi
    done

    log_info "Health check complete: $healthy healthy, $unhealthy unhealthy"

    return 0
}
