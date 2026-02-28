#!/bin/bash
# Checksum Fetching Utilities
#
# This library provides functions to dynamically fetch checksums from various
# sources at build time. This allows feature scripts to verify any version,
# not just pre-stored versions.
#
# Usage:
#   source /tmp/build-scripts/base/checksum-fetch.sh
#   checksum=$(fetch_go_checksum "1.25.3" "amd64")

# Prevent multiple sourcing
if [ -n "${_CHECKSUM_FETCH_LOADED:-}" ]; then
    return 0
fi
_CHECKSUM_FETCH_LOADED=1

set -euo pipefail

# Source retry utilities for rate limiting and backoff
if [ -f /tmp/build-scripts/base/retry-utils.sh ]; then
    source /tmp/build-scripts/base/retry-utils.sh
fi

# ============================================================================
# Internal Helper Functions
# ============================================================================

# _curl_with_timeout - Wrapper for curl with standard timeouts
#
# Arguments:
#   $@ - All arguments passed to curl
#
# Returns:
#   Curl output on success
#   Empty on failure
#
# Note: Internal function, not exported
_curl_with_timeout() {
    command curl --connect-timeout 10 --max-time 30 --retry 3 --retry-delay 2 --retry-all-errors "$@"
}

# _is_partial_version - Check if version string is partial (e.g., "1.23" vs "1.23.0")
#
# Arguments:
#   $1 - Version string to check
#
# Returns:
#   0 if partial version (has exactly 1 dot)
#   1 otherwise
#
# Note: Internal function, not exported
_is_partial_version() {
    local version="$1"
    local dot_count
    dot_count=$(echo "$version" | grep -o '\.' | wc -l)
    [ "$dot_count" -eq 1 ]
}

# _curl_with_retry_wrapper - Use retry_github_api if available, else standard curl
#
# Arguments:
#   $@ - All arguments to pass to curl
#
# Returns:
#   Curl output
#
# Note: Internal function, not exported
_curl_with_retry_wrapper() {
    if command -v retry_github_api >/dev/null 2>&1; then
        retry_github_api curl "$@"
    else
        _curl_with_timeout "$@"
    fi
}

# ============================================================================
# GitHub Release Checksum Fetching
# ============================================================================

# fetch_github_checksums_txt - Fetch checksum from a checksums.txt file
#
# Many GitHub projects publish a checksums.txt or SHA256SUMS file alongside
# their releases. This function fetches and parses these files.
#
# Arguments:
#   $1 - Checksums file URL
#   $2 - Filename to find checksum for
#
# Returns:
#   Checksum string on success
#   Empty string on failure
#
# Example:
#   url="https://github.com/jesseduffield/lazygit/releases/download/v0.56.0/checksums.txt"
#   checksum=$(fetch_github_checksums_txt "$url" "lazygit_0.56.0_Linux_x86_64.tar.gz")
fetch_github_checksums_txt() {
    local checksums_url="$1"
    local filename="$2"

    # Fetch the checksums file and extract the line for our file
    local checksum
    checksum=$(_curl_with_retry_wrapper -fsSL "$checksums_url" | \
        grep -F "$filename" | \
        awk '{print $1}' | \
        head -1)

    if [ -n "$checksum" ]; then
        echo "$checksum"
        return 0
    else
        return 1
    fi
}

# fetch_github_sha256_file - Fetch checksum from individual .sha256 file
#
# Some projects publish individual .sha256 files alongside each binary.
#
# Arguments:
#   $1 - SHA256 file URL (e.g., https://...file.tar.gz.sha256)
#
# Returns:
#   SHA256 checksum string on success
#   Empty string on failure
#
# Example:
#   checksum=$(fetch_github_sha256_file "https://github.com/.../file.tar.gz.sha256")
fetch_github_sha256_file() {
    local sha256_url="$1"

    # Fetch the .sha256 file and extract just the hash
    local checksum
    checksum=$(_curl_with_retry_wrapper -fsSL "$sha256_url" | \
        awk '{print $1}' | \
        head -1)

    if [ -n "$checksum" ] && [[ "$checksum" =~ ^[a-fA-F0-9]{64}$ ]]; then
        echo "$checksum"
        return 0
    else
        return 1
    fi
}

# fetch_github_sha512_file - Fetch checksum from individual .sha512 file
#
# Some projects (like git-cliff) publish SHA512 checksums.
#
# Arguments:
#   $1 - SHA512 file URL (e.g., https://...file.tar.gz.sha512)
#
# Returns:
#   SHA512 checksum string on success
#   Empty string on failure
#
# Example:
#   checksum=$(fetch_github_sha512_file "https://github.com/.../file.tar.gz.sha512")
fetch_github_sha512_file() {
    local sha512_url="$1"

    # Fetch the .sha512 file and extract just the hash
    local checksum
    checksum=$(_curl_with_retry_wrapper -fsSL "$sha512_url" | \
        awk '{print $1}' | \
        head -1)

    if [ -n "$checksum" ] && [[ "$checksum" =~ ^[a-fA-F0-9]{128}$ ]]; then
        echo "$checksum"
        return 0
    else
        return 1
    fi
}

# ============================================================================
# Calculated Checksums (when none are published)
# ============================================================================

# calculate_checksum_sha256 - Download and calculate SHA256 checksum
#
# For projects that don't publish checksums, we can calculate them ourselves.
# WARNING: This provides less security than publisher-provided checksums,
# but is better than no verification.
#
# Arguments:
#   $1 - File URL to download
#
# Returns:
#   SHA256 checksum string on success
#   Empty string on failure
#
# Example:
#   checksum=$(calculate_checksum_sha256 "https://example.com/binary.tar.gz")
calculate_checksum_sha256() {
    local file_url="$1"

    local checksum
    checksum=$(command curl --connect-timeout 10 --max-time 300 --retry 3 --retry-delay 2 --retry-all-errors -fsSL "$file_url" | sha256sum | awk '{print $1}')

    if [ -n "$checksum" ] && [[ "$checksum" =~ ^[a-fA-F0-9]{64}$ ]]; then
        echo "$checksum"
        return 0
    else
        return 1
    fi
}

# ============================================================================
# Utility Functions
# ============================================================================

# validate_checksum_format - Validate checksum format
#
# Arguments:
#   $1 - Checksum string to validate
#   $2 - Expected type: "sha256" or "sha512"
#
# Returns:
#   0 if valid format, 1 otherwise
validate_checksum_format() {
    local checksum="$1"
    local type="${2:-sha256}"

    case "$type" in
        sha256)
            [[ "$checksum" =~ ^[a-fA-F0-9]{64}$ ]]
            ;;
        sha512)
            [[ "$checksum" =~ ^[a-fA-F0-9]{128}$ ]]
            ;;
        *)
            return 1
            ;;
    esac
}

# ============================================================================
# Source sub-modules
# ============================================================================
_CHECKSUM_FETCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_CHECKSUM_FETCH_DIR}/checksum-fetch-go.sh"
source "${_CHECKSUM_FETCH_DIR}/checksum-fetch-ruby.sh"
source "${_CHECKSUM_FETCH_DIR}/checksum-fetch-maven.sh"

# Export functions for use in other scripts
export -f fetch_github_checksums_txt
export -f fetch_github_sha256_file
export -f fetch_github_sha512_file
export -f calculate_checksum_sha256
export -f validate_checksum_format
