#!/bin/bash
# Maven Central Checksum Fetching
#
# Provides fetch_maven_sha256() for fetching checksums from Maven Central.
# Part of the checksum-fetch system (see checksum-fetch.sh).
#
# Usage:
#   source /tmp/build-scripts/base/checksum-fetch.sh  # Sources this automatically
#   checksum=$(fetch_maven_sha256 "$artifact_url")

# Prevent multiple sourcing
if [ -n "${_CHECKSUM_FETCH_MAVEN_LOADED:-}" ]; then
    return 0
fi
_CHECKSUM_FETCH_MAVEN_LOADED=1

# ============================================================================
# Maven Central Checksum Fetching
# ============================================================================

# fetch_maven_sha256 - Fetch SHA256 checksum from Maven Central
#
# Maven Central publishes .sha256 files alongside artifacts.
#
# Arguments:
#   $1 - Artifact base URL (without .sha256 extension)
#
# Returns:
#   SHA256 checksum string on success
#   Empty string on failure
#
# Example:
#   base_url="https://repo.maven.apache.org/maven2/org/springframework/boot/spring-boot-cli/3.5.7/spring-boot-cli-3.5.7-bin.tar.gz"
#   checksum=$(fetch_maven_sha256 "$base_url")
fetch_maven_sha256() {
    local base_url="$1"
    local sha256_url="${base_url}.sha256"

    # Fetch the .sha256 file
    local checksum
    checksum=$(_curl_with_timeout -fsSL "$sha256_url" | command awk '{print $1}' | command head -1)

    if [ -n "$checksum" ] && [[ "$checksum" =~ ^[a-fA-F0-9]{64}$ ]]; then
        echo "$checksum"
        return 0
    else
        return 1
    fi
}

# Export functions for use in other scripts
export -f fetch_maven_sha256
