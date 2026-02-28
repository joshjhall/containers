#!/bin/bash
# Secret scrubbing utilities for build log sanitization
#
# Prevents accidental exposure of tokens, passwords, API keys, and other
# sensitive data in build logs and command output.
#
# Usage:
#   source /tmp/build-scripts/base/secret-scrubbing.sh
#
#   # Scrub a string argument
#   clean=$(scrub_secrets "Authorization: Bearer ghp_abc123")
#
#   # Scrub via stdin (for piping)
#   echo "password=secret123" | scrub_secrets
#
#   # Scrub URLs with embedded credentials
#   clean_url=$(scrub_url "https://user:pass@host.com/path")
#
# Environment Variables:
#   DISABLE_SECRET_SCRUBBING - Set to "true" to bypass all scrubbing (debugging)

# Prevent multiple sourcing
if [ -n "${_SECRET_SCRUBBING_LOADED:-}" ]; then
    return 0
fi
_SECRET_SCRUBBING_LOADED=1

set -euo pipefail

# ============================================================================
# scrub_secrets - Remove sensitive data from text
#
# Accepts input via argument ($1) or stdin. Applies sed-based regex patterns
# to replace secrets with redaction markers.
#
# Arguments:
#   $1 - Text to scrub (optional; reads stdin if omitted)
#
# Returns:
#   Scrubbed text on stdout
#
# Example:
#   scrub_secrets "GITHUB_TOKEN=ghp_xxxx"
#   echo "secret=foo" | scrub_secrets
# ============================================================================
scrub_secrets() {
    # Opt-out for debugging
    if [ "${DISABLE_SECRET_SCRUBBING:-false}" = "true" ]; then
        if [ $# -gt 0 ]; then
            printf '%s\n' "$1"
        else
            command cat
        fi
        return 0
    fi

    # Build sed expression — order matters: specific patterns before generic ones
    local sed_expr

    # The sed expression applies these patterns in order:
    # 1. Authorization headers (Bearer, token, Basic)
    # 2. GitHub tokens (ghp_, github_pat_, gho_, ghu_, ghs_, ghr_)
    # 3. API keys with sk-/pk- prefix
    # 4. Known env var assignments (GITHUB_TOKEN=, AWS_SECRET_ACCESS_KEY=, etc.)
    # 5. Generic password/secret/api_key=value pairs
    # 6. URLs with embedded credentials (user:pass@host)
    sed_expr='
        s|([Aa]uthorization:[[:space:]]*)[Bb]earer[[:space:]]+[^[:space:]"'"'"']+|\1Bearer ***REDACTED***|g
        s|([Aa]uthorization:[[:space:]]*)[Tt]oken[[:space:]]+[^[:space:]"'"'"']+|\1token ***REDACTED***|g
        s|([Aa]uthorization:[[:space:]]*)[Bb]asic[[:space:]]+[^[:space:]"'"'"']+|\1Basic ***REDACTED***|g
        s|ghp_[A-Za-z0-9_]{1,}|***GITHUB_TOKEN_REDACTED***|g
        s|github_pat_[A-Za-z0-9_]{1,}|***GITHUB_TOKEN_REDACTED***|g
        s|gho_[A-Za-z0-9_]{1,}|***GITHUB_TOKEN_REDACTED***|g
        s|ghu_[A-Za-z0-9_]{1,}|***GITHUB_TOKEN_REDACTED***|g
        s|ghs_[A-Za-z0-9_]{1,}|***GITHUB_TOKEN_REDACTED***|g
        s|ghr_[A-Za-z0-9_]{1,}|***GITHUB_TOKEN_REDACTED***|g
        s|sk-[A-Za-z0-9_-]{20,}|***API_KEY_REDACTED***|g
        s|pk-[A-Za-z0-9_-]{20,}|***API_KEY_REDACTED***|g
        s|(GITHUB_TOKEN=)[^[:space:]"'"'"']+|\1***REDACTED***|g
        s|(GH_TOKEN=)[^[:space:]"'"'"']+|\1***REDACTED***|g
        s|(AWS_SECRET_ACCESS_KEY=)[^[:space:]"'"'"']+|\1***REDACTED***|g
        s|(AWS_SESSION_TOKEN=)[^[:space:]"'"'"']+|\1***REDACTED***|g
        s|(ANTHROPIC_API_KEY=)[^[:space:]"'"'"']+|\1***REDACTED***|g
        s|(OPENAI_API_KEY=)[^[:space:]"'"'"']+|\1***REDACTED***|g
        s|(ANTHROPIC_AUTH_TOKEN=)[^[:space:]"'"'"']+|\1***REDACTED***|g
        s|(OP_SERVICE_ACCOUNT_TOKEN=)[^[:space:]"'"'"']+|\1***REDACTED***|g
        s|(password=)[^[:space:]"'"'"'&]+|\1***REDACTED***|g
        s|(PASSWORD=)[^[:space:]"'"'"'&]+|\1***REDACTED***|g
        s|(secret=)[^[:space:]"'"'"'&]+|\1***REDACTED***|g
        s|(SECRET=)[^[:space:]"'"'"'&]+|\1***REDACTED***|g
        s|(api_key=)[^[:space:]"'"'"'&]+|\1***REDACTED***|g
        s|(API_KEY=)[^[:space:]"'"'"'&]+|\1***REDACTED***|g
        s|(secret_key=)[^[:space:]"'"'"'&]+|\1***REDACTED***|g
        s|(SECRET_KEY=)[^[:space:]"'"'"'&]+|\1***REDACTED***|g
        s|(https?://)[^[:space:]@]+:[^[:space:]@]+@|\1***CREDENTIALS***@|g
    '

    if [ $# -gt 0 ]; then
        printf '%s\n' "$1" | command sed -E "$sed_expr"
    else
        command sed -E "$sed_expr"
    fi
}

# ============================================================================
# scrub_url - Scrub credentials from a URL
#
# Specifically targets the user:password@host pattern in URLs.
#
# Arguments:
#   $1 - URL to scrub
#
# Returns:
#   Scrubbed URL on stdout
#
# Example:
#   scrub_url "https://user:pass@github.com/repo"
#   # Output: https://***CREDENTIALS***@github.com/repo
# ============================================================================
scrub_url() {
    if [ "${DISABLE_SECRET_SCRUBBING:-false}" = "true" ]; then
        printf '%s\n' "$1"
        return 0
    fi

    printf '%s\n' "$1" | command sed -E 's|(https?://)[^[:space:]@]+:[^[:space:]@]+@|\1***CREDENTIALS***@|g'
}

# Export functions for use in other scripts
export -f scrub_secrets
export -f scrub_url
