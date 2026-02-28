#!/bin/bash
# Go Checksum Fetching
#
# Provides fetch_go_checksum() for dynamically fetching Go release checksums.
# Part of the checksum-fetch system (see checksum-fetch.sh).
#
# Usage:
#   source /tmp/build-scripts/base/checksum-fetch.sh  # Sources this automatically
#   checksum=$(fetch_go_checksum "1.25.3" "amd64")

# Prevent multiple sourcing
if [ -n "${_CHECKSUM_FETCH_GO_LOADED:-}" ]; then
    return 0
fi
_CHECKSUM_FETCH_GO_LOADED=1

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
        command sed 's/<tt>\|<\/tt>//g' | \
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
            command sed "s/go//; s/\.linux-${arch}\.tar\.gz//" | \
            sort -V | \
            tail -1)

        if [ -n "$matching_versions" ]; then
            # Fetch checksum for the resolved version
            local resolved_filename="go${matching_versions}.linux-${arch}.tar.gz"
            checksum=$(echo "$page_content" | \
                grep -A 5 "${resolved_filename}" | \
                grep -oP '<tt>[a-f0-9]{64}</tt>' | \
                command sed 's/<tt>\|<\/tt>//g' | \
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

# Export functions for use in other scripts
export -f fetch_go_checksum
