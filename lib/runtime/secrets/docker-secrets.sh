#!/bin/bash
# Docker Secrets Integration for Container Runtime
#
# Description:
#   Provides integration with Docker Swarm secrets and Docker Compose secrets.
#   Reads secrets from /run/secrets/ and exports them as environment variables.
#
# Environment Variables:
#   DOCKER_SECRETS_ENABLED     - Enable Docker secrets (true/false, default: auto-detect)
#   DOCKER_SECRETS_DIR         - Directory containing secrets (default: /run/secrets)
#   DOCKER_SECRET_PREFIX       - Prefix for exported env vars (default: empty)
#   DOCKER_SECRET_NAMES        - Comma-separated list of secret names (optional, all if not set)
#   DOCKER_SECRETS_UPPERCASE   - Convert secret names to uppercase (default: true)
#
# How Docker Secrets Work:
#   - Docker Swarm/Compose mounts secrets as files in /run/secrets/
#   - Each secret is a separate file with the secret value as content
#   - File names are the secret names
#   - This script reads these files and exports as environment variables
#
# Usage:
#   source /opt/container-runtime/secrets/docker-secrets.sh
#   load_secrets_from_docker
#
# Exit Codes:
#   0 - Success (secrets loaded or Docker secrets disabled)
#   1 - Configuration error
#   3 - Secret retrieval error

set -euo pipefail

# Source shared logging and helpers
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ============================================================================
# Docker Secrets Detection
# ============================================================================

# Auto-detect if Docker secrets are available
docker_secrets_available() {
    local secrets_dir="${DOCKER_SECRETS_DIR:-/run/secrets}"

    # Check if secrets directory exists and is readable
    if [ -d "$secrets_dir" ] && [ -r "$secrets_dir" ]; then
        # Check if directory has any files (excluding . and ..)
        if [ -n "$(command ls -A "$secrets_dir" 2>/dev/null)" ]; then
            return 0
        fi
    fi

    return 1
}

# ============================================================================
# Secret Loading Functions
# ============================================================================

# Load secrets from Docker secrets directory
load_secrets_from_docker() {
    local secrets_dir="${DOCKER_SECRETS_DIR:-/run/secrets}"
    local enabled="${DOCKER_SECRETS_ENABLED:-auto}"

    # Auto-detect if not explicitly enabled/disabled
    if [ "$enabled" = "auto" ]; then
        if ! docker_secrets_available; then
            log_info "Docker secrets not available (no secrets in $secrets_dir)"
            return 0
        fi
        log_info "Docker secrets detected, loading automatically"
    elif [ "$enabled" != "true" ]; then
        log_info "Docker secrets integration disabled (DOCKER_SECRETS_ENABLED != true)"
        return 0
    fi

    # Verify secrets directory exists
    if [ ! -d "$secrets_dir" ]; then
        log_error "Docker secrets directory not found: $secrets_dir"
        return 1
    fi

    if [ ! -r "$secrets_dir" ]; then
        log_error "Docker secrets directory not readable: $secrets_dir"
        return 1
    fi

    log_info "Loading secrets from Docker secrets directory: $secrets_dir"

    local prefix="${DOCKER_SECRET_PREFIX:-}"
    local uppercase="${DOCKER_SECRETS_UPPERCASE:-true}"
    local count=0

    # Determine which secrets to load
    local secret_files=()
    if [ -n "${DOCKER_SECRET_NAMES:-}" ]; then
        # Specific secrets requested
        IFS=',' read -ra secret_names <<< "$DOCKER_SECRET_NAMES"
        for secret_name in "${secret_names[@]}"; do
            secret_name=$(echo "$secret_name" | xargs)  # Trim whitespace
            if [ -n "$secret_name" ]; then
                # Validate secret name to prevent path traversal
                if ! [[ "$secret_name" =~ ^[a-zA-Z0-9._-]+$ ]]; then
                    log_warning "Invalid secret name rejected (must match [a-zA-Z0-9._-]+): $secret_name"
                    continue
                fi
                secret_files+=("$secrets_dir/$secret_name")
            fi
        done
    else
        # Load all secrets from directory
        while IFS= read -r -d '' secret_file; do
            secret_files+=("$secret_file")
        done < <(command find "$secrets_dir" -maxdepth 1 -type f -print0 2>/dev/null)
    fi

    # Load each secret
    for secret_file in "${secret_files[@]}"; do
        if [ ! -f "$secret_file" ]; then
            log_warning "Secret file not found: $secret_file"
            continue
        fi

        if [ ! -r "$secret_file" ]; then
            log_warning "Secret file not readable: $secret_file"
            continue
        fi

        # Get secret name from filename
        local secret_name
        secret_name=$(basename "$secret_file")

        # Skip hidden files and system files
        if [[ "$secret_name" =~ ^\. ]]; then
            log_info "Skipping hidden file: $secret_name"
            continue
        fi

        # Read secret value
        local secret_value
        secret_value=$(command cat "$secret_file")

        if [ -z "$secret_value" ]; then
            log_warning "Secret '$secret_name' is empty, skipping"
            continue
        fi

        # Convert secret name to valid environment variable name
        # Replace hyphens and dots with underscores
        local env_var_name="${secret_name//-/_}"
        env_var_name="${env_var_name//./_}"

        # Convert to uppercase if requested
        if [ "$uppercase" = "true" ]; then
            env_var_name="${env_var_name^^}"
        fi

        # Add prefix
        env_var_name="${prefix}${env_var_name}"

        # Export as environment variable
        export "${env_var_name}=${secret_value}"
        count=$((count + 1))
        log_info "Loaded secret: $env_var_name"
    done

    log_info "Successfully loaded $count secret(s) from Docker secrets"
    return 0
}

# ============================================================================
# Docker Secrets Health Check
# ============================================================================

# Check if Docker secrets are accessible
docker_secrets_health_check() {
    local secrets_dir="${DOCKER_SECRETS_DIR:-/run/secrets}"

    if [ "${DOCKER_SECRETS_ENABLED:-auto}" = "false" ]; then
        return 0
    fi

    log_info "Checking Docker secrets availability"

    if docker_secrets_available; then
        local count
        count=$(command find "$secrets_dir" -maxdepth 1 -type f 2>/dev/null | command wc -l)
        log_info "Docker secrets available ($count secrets found)"
        return 0
    else
        log_info "Docker secrets not available"
        return 1
    fi
}
