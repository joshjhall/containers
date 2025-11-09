#!/bin/bash
# Retry utilities with exponential backoff for external API calls
#
# This script provides wrapper functions for commands that may fail due to:
# - Rate limiting (e.g., GitHub API)
# - Temporary network issues
# - Service unavailability
#
# Usage:
#   Source this file in your script:
#     source /tmp/build-scripts/base/retry-utils.sh
#
#   Then use:
#     retry_with_backoff curl https://example.com
#     retry_command "description" command args...

set -euo pipefail

# Source logging functions if available
if [ -f /tmp/build-scripts/base/logging.sh ]; then
    source /tmp/build-scripts/base/logging.sh
fi

# ============================================================================
# Configuration
# ============================================================================
RETRY_MAX_ATTEMPTS="${RETRY_MAX_ATTEMPTS:-3}"
RETRY_INITIAL_DELAY="${RETRY_INITIAL_DELAY:-2}"
RETRY_MAX_DELAY="${RETRY_MAX_DELAY:-30}"

# ============================================================================
# retry_with_backoff - Retry a command with exponential backoff
#
# Arguments:
#   $@ - Command and arguments to retry
#
# Usage:
#   retry_with_backoff curl -fsSL https://example.com
#   retry_with_backoff wget -q -O- https://example.com
#
# Environment Variables:
#   RETRY_MAX_ATTEMPTS - Maximum retry attempts (default: 3)
#   RETRY_INITIAL_DELAY - Initial delay in seconds (default: 2)
#   RETRY_MAX_DELAY - Maximum delay in seconds (default: 30)
#
# Exit codes:
#   0 - Command succeeded
#   Non-zero - Command failed after all retries
# ============================================================================
retry_with_backoff() {
    local max_attempts="${RETRY_MAX_ATTEMPTS:-3}"
    local delay="${RETRY_INITIAL_DELAY:-2}"
    local max_delay="${RETRY_MAX_DELAY:-30}"
    local attempt=1
    local exitCode=0

    while [ $attempt -le "$max_attempts" ]; do
        # Try the command
        if "$@"; then
            return 0
        else
            exitCode=$?
        fi

        # If this wasn't the last attempt, wait and retry
        if [ $attempt -lt "$max_attempts" ]; then
            echo "⚠ Attempt $attempt/$max_attempts failed (exit code: $exitCode)" >&2
            echo "  Retrying in ${delay}s..." >&2
            sleep "$delay"

            # Exponential backoff with cap
            delay=$((delay * 2))
            if [ $delay -gt "$max_delay" ]; then
                delay=$max_delay
            fi
        else
            echo "✗ Command failed after $max_attempts attempts" >&2
        fi

        attempt=$((attempt + 1))
    done

    return $exitCode
}

# ============================================================================
# retry_command - Retry a command with logging
#
# Arguments:
#   $1 - Description of the command (for logging)
#   $@ - Command and arguments to retry
#
# Usage:
#   retry_command "Fetching GitHub checksums" curl -fsSL "$URL"
#
# This is a higher-level wrapper that provides better logging integration
# ============================================================================
retry_command() {
    local description="$1"
    shift

    if command -v log_message >/dev/null 2>&1; then
        log_message "Attempting: $description"
    else
        echo "Attempting: $description" >&2
    fi

    if retry_with_backoff "$@"; then
        if command -v log_message >/dev/null 2>&1; then
            log_message "✓ Success: $description"
        fi
        return 0
    else
        local exit_code=$?
        if command -v log_error >/dev/null 2>&1; then
            log_error "Failed: $description (after $RETRY_MAX_ATTEMPTS attempts)"
        else
            echo "✗ Failed: $description (after $RETRY_MAX_ATTEMPTS attempts)" >&2
        fi
        return $exit_code
    fi
}

# ============================================================================
# retry_github_api - Retry GitHub API calls with rate limit awareness
#
# Arguments:
#   $@ - curl command and arguments
#
# Usage:
#   retry_github_api curl -fsSL "https://api.github.com/repos/..."
#
# Features:
#   - Detects rate limiting (HTTP 403 with rate limit message)
#   - Uses GitHub token if available (GITHUB_TOKEN env var)
#   - Provides better error messages for rate limit issues
#
# Environment Variables:
#   GITHUB_TOKEN - GitHub personal access token (optional, increases rate limit)
#   RETRY_MAX_ATTEMPTS - Maximum retry attempts (default: 3)
# ============================================================================
retry_github_api() {
    local max_attempts="${RETRY_MAX_ATTEMPTS:-3}"
    local delay="${RETRY_INITIAL_DELAY:-2}"
    local attempt=1

    while [ $attempt -le "$max_attempts" ]; do
        # Try the command with auth header if GITHUB_TOKEN is available
        local output
        local exit_code=0

        if [ -n "${GITHUB_TOKEN:-}" ]; then
            # Add GitHub token to curl command
            output=$("$@" -H "Authorization: token ${GITHUB_TOKEN}" 2>&1) || exit_code=$?
        else
            output=$("$@" 2>&1) || exit_code=$?
        fi

        if [ $exit_code -eq 0 ]; then
            echo "$output"
            return 0
        fi

        # Check if this is a rate limit error
        if echo "$output" | grep -qi "rate limit\|403"; then
            echo "⚠ GitHub API rate limit detected on attempt $attempt/$max_attempts" >&2
            if [ -z "${GITHUB_TOKEN:-}" ]; then
                echo "  Consider setting GITHUB_TOKEN to increase rate limits:" >&2
                echo "  - Without token: 60 requests/hour" >&2
                echo "  - With token: 5000 requests/hour" >&2
            fi
        fi

        # Retry if not last attempt
        if [ $attempt -lt "$max_attempts" ]; then
            echo "  Retrying in ${delay}s..." >&2
            sleep "$delay"
            delay=$((delay * 2))
        fi

        attempt=$((attempt + 1))
    done

    echo "✗ GitHub API call failed after $max_attempts attempts" >&2
    return 1
}

# Export functions for use by other scripts
export -f retry_with_backoff
export -f retry_command
export -f retry_github_api
