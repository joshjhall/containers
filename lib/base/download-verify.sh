#!/bin/bash
# Download and Verify - Secure file download with checksum verification
#
# Description:
#   Provides secure download functions with SHA256 checksum verification.
#   Prevents supply chain attacks by validating file integrity before use.
#
# Usage:
#   source /tmp/build-scripts/base/download-verify.sh
#   download_and_verify "URL" "EXPECTED_SHA256" "/output/path"
#   download_and_extract "URL" "EXPECTED_SHA256" "/extract/dir" "file_to_extract"
#
# Functions:
#   - download_and_verify: Download file and verify SHA256
#   - download_and_extract: Download tarball, verify, and extract specific file
#   - verify_checksum: Verify existing file's SHA256 checksum
#
# Security:
#   - All downloads must provide expected SHA256 checksum
#   - Files are verified before extraction or execution
#   - Temporary files are cleaned up on verification failure
#
# Note:
#   This script should be sourced by feature scripts that download binaries.
#   Checksums should be obtained from official sources and pinned in scripts.

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ============================================================================
# Core Download and Verification Functions
# ============================================================================

# download_and_verify - Download a file and verify its SHA256 or SHA512 checksum
#
# Arguments:
#   $1 - URL to download
#   $2 - Expected checksum (SHA256 64 hex chars or SHA512 128 hex chars)
#   $3 - Output file path
#
# Returns:
#   0 on success, 1 on failure
#
# Example:
#   download_and_verify \
#     "https://example.com/tool.tar.gz" \
#     "abc123..." \
#     "/tmp/tool.tar.gz"
download_and_verify() {
    local url="$1"
    local expected_checksum="$2"
    local output_path="$3"
    local temp_file="${output_path}.tmp"

    echo "→ Downloading: $(basename "$output_path")"
    echo "  URL: $url"

    # Download to temporary file
    if ! curl -fsSL -o "$temp_file" "$url"; then
        echo -e "${RED}✗ Download failed${NC}" >&2
        rm -f "$temp_file"
        return 1
    fi

    echo "→ Verifying checksum..."

    # Verify checksum
    if ! verify_checksum "$temp_file" "$expected_checksum"; then
        echo -e "${RED}✗ Checksum verification failed${NC}" >&2
        echo "  Expected: $expected_checksum" >&2

        # Determine hash type for error message
        local checksum_len="${#expected_checksum}"
        if [ "$checksum_len" -eq 64 ]; then
            echo "  Got:      $(sha256sum "$temp_file" | cut -d' ' -f1)" >&2
        else
            echo "  Got:      $(sha512sum "$temp_file" | cut -d' ' -f1)" >&2
        fi
        rm -f "$temp_file"
        return 1
    fi

    # Move verified file to final destination
    mv "$temp_file" "$output_path"
    echo -e "${GREEN}✓ Download verified successfully${NC}"
    return 0
}

# download_and_extract - Download tarball, verify, and extract specific file(s)
#
# Arguments:
#   $1 - URL to download
#   $2 - Expected SHA256 checksum of tarball
#   $3 - Directory to extract to
#   $4 - File(s) to extract (optional, extracts all if omitted)
#
# Returns:
#   0 on success, 1 on failure
#
# Example:
#   download_and_extract \
#     "https://example.com/tool.tar.gz" \
#     "abc123..." \
#     "/usr/local/bin" \
#     "tool"
download_and_extract() {
    local url="$1"
    local expected_sha256="$2"
    local extract_dir="$3"
    local files_to_extract="${4:-}"
    local temp_tarball="/tmp/download-verify-$$.tar.gz"

    # Download and verify tarball
    if ! download_and_verify "$url" "$expected_sha256" "$temp_tarball"; then
        return 1
    fi

    echo "→ Extracting to: $extract_dir"

    # Create extraction directory if it doesn't exist
    mkdir -p "$extract_dir"

    # Extract file(s)
    if [ -z "$files_to_extract" ]; then
        # Extract all files
        if ! tar -xzf "$temp_tarball" -C "$extract_dir"; then
            echo -e "${RED}✗ Extraction failed${NC}" >&2
            rm -f "$temp_tarball"
            return 1
        fi
    else
        # Extract specific file(s)
        if ! tar -xzf "$temp_tarball" -C "$extract_dir" "$files_to_extract"; then
            echo -e "${RED}✗ Extraction failed${NC}" >&2
            rm -f "$temp_tarball"
            return 1
        fi
    fi

    # Cleanup
    rm -f "$temp_tarball"
    echo -e "${GREEN}✓ Extraction completed${NC}"
    return 0
}

# verify_checksum - Verify SHA256 or SHA512 checksum of existing file
#
# Arguments:
#   $1 - File path to verify
#   $2 - Expected checksum (SHA256 64 hex chars or SHA512 128 hex chars)
#
# Returns:
#   0 if checksum matches, 1 if mismatch or error
#
# Example:
#   verify_checksum "/tmp/file.tar.gz" "abc123..."
verify_checksum() {
    local file_path="$1"
    local expected_checksum="$2"

    if [ ! -f "$file_path" ]; then
        echo -e "${RED}✗ File not found: $file_path${NC}" >&2
        return 1
    fi

    # Determine hash type based on checksum length
    local checksum_len="${#expected_checksum}"
    local actual_checksum

    if [ "$checksum_len" -eq 64 ]; then
        # SHA256 (64 hexadecimal characters)
        actual_checksum=$(sha256sum "$file_path" | cut -d' ' -f1)
    elif [ "$checksum_len" -eq 128 ]; then
        # SHA512 (128 hexadecimal characters)
        actual_checksum=$(sha512sum "$file_path" | cut -d' ' -f1)
    else
        echo -e "${RED}✗ Invalid checksum length: $checksum_len${NC}" >&2
        echo "  Expected 64 (SHA256) or 128 (SHA512) hex characters" >&2
        return 1
    fi

    # Compare checksums (case-insensitive)
    if [ "${actual_checksum,,}" = "${expected_checksum,,}" ]; then
        echo -e "${GREEN}✓ Checksum verified${NC}"
        return 0
    else
        echo -e "${RED}✗ Checksum mismatch${NC}" >&2
        return 1
    fi
}

# ============================================================================
# Helper Functions
# ============================================================================

# get_github_release_checksum - Helper to get checksums from GitHub releases
#
# Note: This is a placeholder. In practice, checksums should be hardcoded
# in feature scripts after verifying them from official sources.
#
# Arguments:
#   $1 - GitHub repo (e.g., "derailed/k9s")
#   $2 - Version (e.g., "v0.32.4")
#   $3 - Asset name pattern (e.g., "k9s_Linux_amd64.tar.gz")
#
# Returns:
#   SHA256 checksum if found in checksums file
get_github_release_checksum() {
    local repo="$1"
    local version="$2"
    local asset_name="$3"

    echo -e "${YELLOW}⚠ Note: Checksums should be hardcoded in scripts${NC}" >&2
    echo -e "${YELLOW}  This function is for reference only${NC}" >&2

    # Try to find checksums file
    local checksums_url="https://github.com/${repo}/releases/download/${version}/checksums.txt"
    local checksums

    if checksums=$(curl -fsSL "$checksums_url" 2>/dev/null); then
        echo "$checksums" | grep "$asset_name" | cut -d' ' -f1
    else
        echo -e "${RED}✗ Could not fetch checksums from GitHub${NC}" >&2
        return 1
    fi
}

# ============================================================================
# Validation
# ============================================================================

# Ensure sha256sum and sha512sum are available
if ! command -v sha256sum >/dev/null 2>&1; then
    echo -e "${RED}✗ sha256sum not found. Install coreutils package.${NC}" >&2
    exit 1
fi

if ! command -v sha512sum >/dev/null 2>&1; then
    echo -e "${RED}✗ sha512sum not found. Install coreutils package.${NC}" >&2
    exit 1
fi

# Export functions for use in other scripts
export -f download_and_verify
export -f download_and_extract
export -f verify_checksum
