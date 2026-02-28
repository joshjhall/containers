#!/bin/bash
# Ruby Checksum Fetching
#
# Provides fetch_ruby_checksum() for dynamically fetching Ruby release checksums.
# Part of the checksum-fetch system (see checksum-fetch.sh).
#
# Usage:
#   source /tmp/build-scripts/base/checksum-fetch.sh  # Sources this automatically
#   checksum=$(fetch_ruby_checksum "3.4.7")

# Prevent multiple sourcing
if [ -n "${_CHECKSUM_FETCH_RUBY_LOADED:-}" ]; then
    return 0
fi
_CHECKSUM_FETCH_RUBY_LOADED=1

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
        command grep -A2 ">Ruby ${version}" | \
        command grep -oP 'sha256: \K[a-f0-9]{64}' | \
        command head -1)

    if [ -n "$checksum" ] && [[ "$checksum" =~ ^[a-fA-F0-9]{64}$ ]]; then
        echo "$checksum"
        return 0
    fi

    # If exact match failed, try partial version resolution (e.g., "3.3" -> "3.3.10")
    if _is_partial_version "$version"; then
        # Partial version like "3.3", find all matching versions
        local matching_versions
        matching_versions=$(echo "$page_content" | \
            command grep -oP ">Ruby ${version}\.\d+" | \
            command sed 's/>Ruby //' | \
            command sort -V | \
            command tail -1)

        if [ -n "$matching_versions" ]; then
            # Fetch checksum for the resolved version
            checksum=$(echo "$page_content" | \
                command grep -A2 ">Ruby ${matching_versions}" | \
                command grep -oP 'sha256: \K[a-f0-9]{64}' | \
                command head -1)

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

# Export functions for use in other scripts
export -f fetch_ruby_checksum
