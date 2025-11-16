#!/bin/bash
# Checksum Update Helpers - Shared utilities for fetching and updating checksums
#
# Description:
#   Provides reusable functions for fetching checksums from various sources
#   and updating them in feature scripts. Used by feature-specific checksum
#   updater scripts.
#
# Usage:
#   source bin/lib/update-versions/helpers.sh
#   fetch_github_checksum_file "owner/repo" "v1.2.3" "checksums.txt" "pattern"
#   update_checksum_variable "path/to/script.sh" "VARIABLE_NAME" "new_checksum"

# Header guard to prevent multiple sourcing
if [ -n "${_BIN_LIB_UPDATE_VERSIONS_HELPERS_SH_INCLUDED:-}" ]; then
    return 0
fi
readonly _BIN_LIB_UPDATE_VERSIONS_HELPERS_SH_INCLUDED=1

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared utilities
source "${SCRIPT_DIR}/../common.sh"
source "${SCRIPT_DIR}/../version-utils.sh"

# ============================================================================
# GitHub Release Checksum Functions
# ============================================================================

# fetch_github_checksum_file - Download a checksum file from GitHub releases
#
# Arguments:
#   $1 - GitHub repo (e.g., "derailed/k9s")
#   $2 - Version tag (e.g., "v0.50.16")
#   $3 - Checksum filename (e.g., "checksums.sha256" or "checksums.txt")
#
# Returns:
#   Outputs checksum file contents to stdout
#   Returns 0 on success, 1 on failure
#
# Example:
#   checksums=$(fetch_github_checksum_file "derailed/k9s" "v0.50.16" "checksums.sha256")
fetch_github_checksum_file() {
    local repo="$1"
    local version="$2"
    local checksum_file="$3"
    local url="https://github.com/${repo}/releases/download/${version}/${checksum_file}"

    log_info "Fetching checksums from: $url" >&2

    if ! command curl-fsSL "$url"; then
        log_error "Failed to download checksum file from $url"
        return 1
    fi
}

# extract_checksum_from_file - Extract specific checksum from checksums file
#
# Arguments:
#   $1 - Pattern to match (e.g., "k9s_Linux_amd64.tar.gz")
#   (checksums read from stdin)
#
# Returns:
#   Outputs the checksum (first field) if found
#   Returns 0 on success, 1 if not found
#
# Example:
#   checksum=$(echo "$checksums" | extract_checksum_from_file "k9s_Linux_amd64.tar.gz")
extract_checksum_from_file() {
    local pattern="$1"

    # Read from stdin
    local checksums
    checksums=$(cat)

    # Extract checksum (assumes format: "checksum  filename")
    local checksum
    checksum=$(echo "$checksums" | grep -E "${pattern}$" | awk '{print $1}' | head -1)

    if [ -z "$checksum" ]; then
        log_error "Checksum not found for pattern: $pattern" >&2
        return 1
    fi

    echo "$checksum"
}

# fetch_github_checksum - Fetch a specific checksum from GitHub release
#
# Arguments:
#   $1 - GitHub repo (e.g., "derailed/k9s")
#   $2 - Version tag (e.g., "v0.50.16")
#   $3 - Checksum filename (e.g., "checksums.sha256")
#   $4 - Asset pattern (e.g., "k9s_Linux_amd64.tar.gz")
#
# Returns:
#   Outputs the checksum for the specified asset
#   Returns 0 on success, 1 on failure
#
# Example:
#   checksum=$(fetch_github_checksum "derailed/k9s" "v0.50.16" "checksums.sha256" "k9s_Linux_amd64.tar.gz")
fetch_github_checksum() {
    local repo="$1"
    local version="$2"
    local checksum_file="$3"
    local asset_pattern="$4"

    local checksums
    if ! checksums=$(fetch_github_checksum_file "$repo" "$version" "$checksum_file"); then
        return 1
    fi

    echo "$checksums" | extract_checksum_from_file "$asset_pattern"
}

# fetch_github_individual_checksum - Fetch from individual .sha256 file
#
# Some projects provide individual .sha256 files instead of a combined checksums file
#
# Arguments:
#   $1 - GitHub repo (e.g., "kubernetes-sigs/krew")
#   $2 - Version tag (e.g., "v0.4.5")
#   $3 - Asset name (e.g., "krew-linux_amd64.tar.gz")
#
# Returns:
#   Outputs the checksum
#   Returns 0 on success, 1 on failure
#
# Example:
#   checksum=$(fetch_github_individual_checksum "kubernetes-sigs/krew" "v0.4.5" "krew-linux_amd64.tar.gz")
fetch_github_individual_checksum() {
    local repo="$1"
    local version="$2"
    local asset_name="$3"
    local url="https://github.com/${repo}/releases/download/${version}/${asset_name}.sha256"

    log_info "Fetching checksum from: $url" >&2

    local checksum
    if ! checksum=$(command curl -fsSL "$url"); then
        log_error "Failed to download checksum from $url"
        return 1
    fi

    # Output only the checksum (strip any whitespace/newlines)
    echo "$checksum" | tr -d ' \n\r'
}

# ============================================================================
# Checksum Update Functions
# ============================================================================

# update_checksum_variable - Update checksum variable in a shell script
#
# Arguments:
#   $1 - Path to script file
#   $2 - Variable name (e.g., "K9S_AMD64_SHA256")
#   $3 - New checksum value
#
# Returns:
#   0 on success, 1 on failure
#
# Example:
#   update_checksum_variable "lib/features/kubernetes.sh" "K9S_AMD64_SHA256" "abc123..."
update_checksum_variable() {
    local script_file="$1"
    local variable_name="$2"
    local new_checksum="$3"

    if [ ! -f "$script_file" ]; then
        log_error "Script file not found: $script_file"
        return 1
    fi

    # Validate checksum format (SHA256 is 64 hex, SHA512 is 128 hex)
    if validate_sha256 "$new_checksum"; then
        # Valid SHA256
        :
    elif validate_sha512 "$new_checksum"; then
        # Valid SHA512
        :
    else
        log_error "Invalid checksum format: $new_checksum"
        log_error "Expected SHA256 (64 hex) or SHA512 (128 hex)"
        return 1
    fi

    log_info "Updating ${variable_name} in $(basename "$script_file")..."

    # Use command sed to update the variable assignment
    # Match: VARIABLE_NAME="old_value"
    # Replace with: VARIABLE_NAME="new_value"
    if command sed -i "s/^${variable_name}=\"[^\"]*\"/${variable_name}=\"${new_checksum}\"/" "$script_file"; then
        log_success "Updated ${variable_name}"
        return 0
    else
        log_error "Failed to update ${variable_name} in $script_file"
        return 1
    fi
}

# Note: validate_sha256() and validate_sha512() are now in bin/lib/version-utils.sh

# update_version_comment - Update version verification comment
#
# Arguments:
#   $1 - Path to script file
#   $2 - Comment pattern to find (e.g., "# Verified on:")
#   $3 - New date (e.g., "2025-11-07")
#
# Returns:
#   0 on success, 1 on failure
update_version_comment() {
    local script_file="$1"
    local comment_pattern="$2"
    local new_date="$3"

    if [ ! -f "$script_file" ]; then
        log_error "Script file not found: $script_file"
        return 1
    fi

    log_info "Updating verification date in $(basename "$script_file")..."

    if command sed -i "s|${comment_pattern}.*|${comment_pattern} ${new_date}|" "$script_file"; then
        log_success "Updated verification date"
        return 0
    else
        log_warning "Could not update verification date (may not exist)"
        return 0  # Non-fatal
    fi
}

# ============================================================================
# Validation Functions
# ============================================================================

# verify_checksum_update - Verify that checksum was actually updated
#
# Arguments:
#   $1 - Path to script file
#   $2 - Variable name
#   $3 - Expected new checksum
#
# Returns:
#   0 if verified, 1 if mismatch
verify_checksum_update() {
    local script_file="$1"
    local variable_name="$2"
    local expected_checksum="$3"

    local actual_checksum
    actual_checksum=$(grep "^${variable_name}=" "$script_file" | cut -d'"' -f2)

    if [ "$actual_checksum" = "$expected_checksum" ]; then
        log_success "Verified ${variable_name} update"
        return 0
    else
        log_error "Checksum mismatch for ${variable_name}"
        log_error "  Expected: $expected_checksum"
        log_error "  Actual:   $actual_checksum"
        return 1
    fi
}

# ============================================================================
# Utility Functions
# ============================================================================

# Note: get_current_date() and require_command() are now in bin/lib/common.sh

# Initialize - Check for required commands
require_command curl
require_command sed
require_command awk
require_command grep

log_info "Checksum update helpers loaded"
