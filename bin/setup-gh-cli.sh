#!/bin/bash
set -euo pipefail

# GitHub CLI Authentication Setup
# Version: 1.0.0
#
# Purpose: Authenticate GitHub CLI (gh) using token from 1Password
# Designed to be idempotent and secure for development environments
#
# Usage:
#   bash setup-gh-cli.sh
#
# Environment Variables:
#   OP_SERVICE_ACCOUNT_TOKEN - 1Password service account token (required)
#   GH_TOKEN_VAULT          - 1Password vault name (default: "Development")
#   GH_TOKEN_ITEM           - 1Password item name (default: "GitHub Development Token")
#   GITHUB_TOKEN            - Alternative: GitHub token directly (not recommended)
#
# Security:
# - Token stored securely in 1Password
# - Token loaded into session environment only
# - Uses gh CLI's secure authentication mechanism
# - Idempotent - safe to run multiple times
#
# Note: This script authenticates gh CLI but does NOT configure git to use gh
# for authentication. Git operations should use SSH (configured by setup-git-ssh.sh).

# ============================================================================
# Configuration
# ============================================================================

# Default values
DEFAULT_GH_TOKEN_VAULT="Development"
DEFAULT_GH_TOKEN_ITEM="GitHub Development Token"

# Load environment variables from .env if available
load_env_file() {
    local env_locations=(
        ".env"
        "${HOME}/.env"
        "/workspace/containers/.env"
    )

    for env_file in "${env_locations[@]}"; do
        if [ -f "$env_file" ]; then
            # shellcheck disable=SC1090
            set -a && source "$env_file" && set +a
            echo "✓ Loaded environment from: $env_file" >&2
            return 0
        fi
    done

    return 1
}

# ============================================================================
# Functions
# ============================================================================

# Sanitize token by stripping all whitespace (newlines, spaces, etc.)
sanitize_token() {
    local token="$1"
    # Remove all whitespace characters including newlines, tabs, spaces
    echo "$token" | tr -d '[:space:]'
}

log_info() {
    echo "ℹ️  $*" >&2
}

log_success() {
    echo "✅ $*" >&2
}

log_error() {
    echo "❌ $*" >&2
}

log_warn() {
    echo "⚠️  $*" >&2
}

# Check if gh CLI is installed
check_gh_installed() {
    if ! command -v gh >/dev/null 2>&1; then
        log_error "GitHub CLI (gh) is not installed"
        log_info "Install with: sudo apt-get install gh"
        return 1
    fi
    log_success "GitHub CLI (gh) is installed"
    return 0
}

# Check if already authenticated
check_gh_authenticated() {
    if gh auth status >/dev/null 2>&1; then
        log_success "GitHub CLI is already authenticated"

        # Show current authentication status
        log_info "Current authentication:"
        gh auth status 2>&1 | head -3 || true

        return 0
    fi

    return 1
}

# Check if 1Password CLI is installed and configured
check_op_available() {
    if ! command -v op >/dev/null 2>&1; then
        log_error "1Password CLI (op) is not installed"
        return 1
    fi

    if [ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
        log_error "OP_SERVICE_ACCOUNT_TOKEN is not set"
        log_info "Set it in .env or environment"
        return 1
    fi

    log_success "1Password CLI is available"
    return 0
}

# Fetch GitHub token from 1Password
fetch_github_token_from_op() {
    local vault="${GH_TOKEN_VAULT:-$DEFAULT_GH_TOKEN_VAULT}"
    local item="${GH_TOKEN_ITEM:-$DEFAULT_GH_TOKEN_ITEM}"

    log_info "Fetching GitHub token from 1Password..."
    log_info "  Vault: $vault"
    log_info "  Item: $item"

    # Try to fetch the token (using --no-newline to avoid trailing newlines)
    # Note: stderr passes through to terminal, only stdout is captured
    local token
    if ! token=$(op read --no-newline "op://$vault/$item/credential"); then
        log_error "Failed to fetch GitHub token from 1Password"
        log_info "Make sure the item exists: op://$vault/$item/credential"
        return 1
    fi

    if [ -z "$token" ]; then
        log_error "GitHub token is empty"
        return 1
    fi

    # Validate token format (should start with ghp_ or github_pat_)
    if [[ ! "$token" =~ ^(ghp_|github_pat_) ]]; then
        log_warn "Token format may be invalid (expected ghp_* or github_pat_*)"
    fi

    log_success "GitHub token fetched successfully"

    # Return token via stdout
    echo "$token"
    return 0
}

# Authenticate gh CLI with token
authenticate_gh() {
    local token="$1"

    log_info "Authenticating GitHub CLI..."

    # Use gh auth login with token via stdin
    if echo "$token" | gh auth login --with-token 2>&1; then
        log_success "GitHub CLI authenticated successfully"
        return 0
    else
        log_error "Failed to authenticate GitHub CLI"
        return 1
    fi
}

# Export GITHUB_TOKEN to session environment
export_github_token() {
    local token="$1"

    # Sanitize token before exporting
    token=$(sanitize_token "$token")

    # Export for current session
    export GITHUB_TOKEN="$token"

    # Also append to ~/.bashrc for persistence in shell sessions
    # Only if not already present
    if ! grep -q "export GITHUB_TOKEN=" "$HOME/.bashrc" 2>/dev/null; then
        cat >> "$HOME/.bashrc" <<'EOF'

# GitHub token (set by setup-gh-cli.sh)
# Note: This will be re-exported on each container start
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    export GITHUB_TOKEN=$(gh auth token 2>/dev/null | tr -d '[:space:]')
fi
EOF
        log_success "Added GITHUB_TOKEN export to ~/.bashrc"
    fi

    log_success "GITHUB_TOKEN exported to session"
    return 0
}

# Verify authentication works
verify_gh_auth() {
    log_info "Verifying GitHub CLI authentication..."

    # Test with a simple gh command
    if gh auth status >/dev/null 2>&1; then
        log_success "GitHub CLI authentication verified"

        # Show authenticated user
        local username
        username=$(gh api user --jq .login 2>/dev/null || echo "unknown")
        log_info "Authenticated as: $username"

        return 0
    else
        log_error "GitHub CLI authentication verification failed"
        return 1
    fi
}

# ============================================================================
# Main
# ============================================================================

main() {
    echo "" >&2
    echo "========================================" >&2
    echo "GitHub CLI Authentication Setup" >&2
    echo "========================================" >&2
    echo "" >&2

    # Load environment variables
    load_env_file || log_warn "No .env file found (this is optional)"

    # Check if gh is installed
    if ! check_gh_installed; then
        exit 1
    fi

    # Check if already authenticated (idempotent)
    if check_gh_authenticated; then
        log_info "Skipping authentication setup (already configured)"

        # Still export GITHUB_TOKEN if authenticated
        if command -v gh >/dev/null 2>&1; then
            local existing_token
            existing_token=$(gh auth token 2>/dev/null || echo "")
            if [ -n "$existing_token" ]; then
                # Sanitize token to remove any trailing whitespace
                existing_token=$(sanitize_token "$existing_token")
                export GITHUB_TOKEN="$existing_token"
                log_success "GITHUB_TOKEN exported from existing gh auth"
            fi
        fi

        echo "" >&2
        log_success "GitHub CLI setup complete"
        echo "" >&2
        return 0
    fi

    # Try to get token from environment first
    local token="${GITHUB_TOKEN:-}"

    # If not in environment, try 1Password
    if [ -z "$token" ]; then
        if check_op_available; then
            token=$(fetch_github_token_from_op) || {
                log_error "Failed to fetch GitHub token"
                exit 1
            }
        else
            log_error "No GitHub token available"
            log_info "Either:"
            log_info "  1. Set GITHUB_TOKEN in .env"
            log_info "  2. Configure 1Password with OP_SERVICE_ACCOUNT_TOKEN"
            exit 1
        fi
    else
        log_info "Using GITHUB_TOKEN from environment"
        # Sanitize token from environment (may have trailing whitespace)
        token=$(sanitize_token "$token")
    fi

    # Authenticate gh CLI
    if ! authenticate_gh "$token"; then
        exit 1
    fi

    # Export token to session
    export_github_token "$token"

    # Verify authentication
    if ! verify_gh_auth; then
        exit 1
    fi

    echo "" >&2
    log_success "GitHub CLI setup complete"
    echo "" >&2
    log_info "You can now use 'gh' commands:"
    log_info "  gh repo list"
    log_info "  gh pr list"
    log_info "  gh issue list"
    echo "" >&2
    log_info "Note: Git operations will use SSH (not gh) per your configuration"
    echo "" >&2
}

# Run main function
main "$@"
