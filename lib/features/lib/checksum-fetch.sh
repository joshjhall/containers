#!/bin/bash
# Checksum Fetching Utilities
#
# This library provides functions to dynamically fetch checksums from various
# sources at build time. This allows feature scripts to verify any version,
# not just pre-stored versions.
#
# Usage:
#   source /tmp/build-scripts/features/lib/checksum-fetch.sh
#   checksum=$(fetch_go_checksum "1.25.3" "amd64")

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
    curl --connect-timeout 10 --max-time 30 "$@"
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
# Go Checksum Fetching
# ============================================================================

# fetch_go_checksum - Fetch SHA256 checksum for a Go release
#
# Arguments:
#   $1 - Go version (e.g., "1.25.3", "1.23")
#   $2 - Architecture (e.g., "amd64", "arm64")
#
# Returns:
#   SHA256 checksum string on success
#   Empty string on failure
#
# Supports partial versions:
#   "1.23" resolves to latest 1.23.x (e.g., "1.23.0")
#   "1.25.3" matches exactly
#
# Example:
#   checksum=$(fetch_go_checksum "1.25.3" "arm64")
#   checksum=$(fetch_go_checksum "1.23" "amd64")  # Resolves to 1.23.0
fetch_go_checksum() {
    local version="$1"
    local arch="$2"
    local url="https://go.dev/dl/"
    local page_content

    page_content=$(_curl_with_timeout -fsSL "$url")

    # Try exact match first
    local filename="go${version}.linux-${arch}.tar.gz"
    local checksum
    checksum=$(echo "$page_content" | \
        grep -A 5 "${filename}" | \
        grep -oP '<tt>[a-f0-9]{64}</tt>' | \
        sed 's/<tt>\|<\/tt>//g' | \
        head -1)

    if [ -n "$checksum" ] && [[ "$checksum" =~ ^[a-fA-F0-9]{64}$ ]]; then
        echo "$checksum"
        return 0
    fi

    # If exact match failed, try partial version resolution (e.g., "1.23" -> "1.23.0")
    if _is_partial_version "$version"; then
        # Partial version like "1.23", find all matching versions
        local matching_versions
        matching_versions=$(echo "$page_content" | \
            grep -oP "go${version}\.\d+\.linux-${arch}\.tar\.gz" | \
            sed "s/go//; s/\.linux-${arch}\.tar\.gz//" | \
            sort -V | \
            tail -1)

        if [ -n "$matching_versions" ]; then
            # Fetch checksum for the resolved version
            local resolved_filename="go${matching_versions}.linux-${arch}.tar.gz"
            checksum=$(echo "$page_content" | \
                grep -A 5 "${resolved_filename}" | \
                grep -oP '<tt>[a-f0-9]{64}</tt>' | \
                sed 's/<tt>\|<\/tt>//g' | \
                head -1)

            if [ -n "$checksum" ] && [[ "$checksum" =~ ^[a-fA-F0-9]{64}$ ]]; then
                # Export resolved version for the caller to use
                export GO_RESOLVED_VERSION="$matching_versions"
                echo "$checksum"
                return 0
            fi
        fi
    fi

    return 1
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
# Maven Central Checksum Fetching
# ============================================================================

# fetch_maven_sha1 - Fetch SHA1 checksum from Maven Central
#
# Maven Central publishes .sha1 files alongside artifacts.
#
# Arguments:
#   $1 - Artifact base URL (without .sha1 extension)
#
# Returns:
#   SHA1 checksum string on success
#   Empty string on failure
#
# Example:
#   base_url="https://repo.maven.apache.org/maven2/org/springframework/boot/spring-boot-cli/3.5.7/spring-boot-cli-3.5.7-bin.tar.gz"
#   checksum=$(fetch_maven_sha1 "$base_url")
fetch_maven_sha1() {
    local base_url="$1"
    local sha1_url="${base_url}.sha1"

    # Fetch the .sha1 file
    local checksum
    checksum=$(_curl_with_timeout -fsSL "$sha1_url" | awk '{print $1}' | head -1)

    if [ -n "$checksum" ] && [[ "$checksum" =~ ^[a-fA-F0-9]{40}$ ]]; then
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
    checksum=$(curl --connect-timeout 10 --max-time 300 -fsSL "$file_url" | sha256sum | awk '{print $1}')

    if [ -n "$checksum" ] && [[ "$checksum" =~ ^[a-fA-F0-9]{64}$ ]]; then
        echo "$checksum"
        return 0
    else
        return 1
    fi
}

# ============================================================================
# Ruby Checksum Fetching
# ============================================================================

# fetch_ruby_checksum - Fetch SHA256 checksum for a Ruby release
#
# Arguments:
#   $1 - Ruby version (e.g., "3.4.7", "3.3.10", "3.3")
#
# Returns:
#   SHA256 checksum string on success
#   Empty string on failure
#
# Supports partial versions:
#   "3.3" resolves to latest 3.3.x (e.g., "3.3.10")
#   "3.4.7" matches exactly
#
# Example:
#   checksum=$(fetch_ruby_checksum "3.4.7")
#   checksum=$(fetch_ruby_checksum "3.3")  # Resolves to 3.3.10
fetch_ruby_checksum() {
    local version="$1"
    local url="https://www.ruby-lang.org/en/downloads/"
    local page_content

    page_content=$(_curl_with_timeout -fsSL "$url")

    # Try exact match first
    local checksum
    checksum=$(echo "$page_content" | \
        grep -A2 ">Ruby ${version}" | \
        grep -oP 'sha256: \K[a-f0-9]{64}' | \
        head -1)

    if [ -n "$checksum" ] && [[ "$checksum" =~ ^[a-fA-F0-9]{64}$ ]]; then
        echo "$checksum"
        return 0
    fi

    # If exact match failed, try partial version resolution (e.g., "3.3" -> "3.3.10")
    if _is_partial_version "$version"; then
        # Partial version like "3.3", find all matching versions
        local matching_versions
        matching_versions=$(echo "$page_content" | \
            grep -oP ">Ruby ${version}\.\d+" | \
            sed 's/>Ruby //' | \
            sort -V | \
            tail -1)

        if [ -n "$matching_versions" ]; then
            # Fetch checksum for the resolved version
            checksum=$(echo "$page_content" | \
                grep -A2 ">Ruby ${matching_versions}" | \
                grep -oP 'sha256: \K[a-f0-9]{64}' | \
                head -1)

            if [ -n "$checksum" ] && [[ "$checksum" =~ ^[a-fA-F0-9]{64}$ ]]; then
                # Export resolved version for the caller to use
                export RUBY_RESOLVED_VERSION="$matching_versions"
                echo "$checksum"
                return 0
            fi
        fi
    fi

    return 1
}

# ============================================================================
# Utility Functions
# ============================================================================

# validate_checksum_format - Validate checksum format
#
# Arguments:
#   $1 - Checksum string to validate
#   $2 - Expected type: "sha1", "sha256", or "sha512"
#
# Returns:
#   0 if valid format, 1 otherwise
validate_checksum_format() {
    local checksum="$1"
    local type="${2:-sha256}"

    case "$type" in
        sha1)
            [[ "$checksum" =~ ^[a-fA-F0-9]{40}$ ]]
            ;;
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

# Export functions for use in other scripts
export -f fetch_go_checksum
export -f fetch_github_checksums_txt
export -f fetch_github_sha256_file
export -f fetch_github_sha512_file
export -f fetch_ruby_checksum
export -f fetch_maven_sha1
export -f calculate_checksum_sha256
export -f validate_checksum_format
