#!/bin/bash
# Terraform GPG Verification
#
# Provides download_and_verify_terraform_gpg() for Terraform-specific GPG verification.
# Part of the GPG verification system (see gpg-verify.sh).
#
# Usage:
#   source /tmp/build-scripts/base/gpg-verify.sh  # Sources this automatically
#   download_and_verify_terraform_gpg "terraform_1.10.0_linux_amd64.zip" "1.10.0"

# Prevent multiple sourcing
if [ -n "${_GPG_VERIFY_TERRAFORM_LOADED:-}" ]; then
    return 0
fi
_GPG_VERIFY_TERRAFORM_LOADED=1

# ============================================================================
# download_and_verify_terraform_gpg - Terraform-specific GPG verification
#
# HashiCorp uses a signed SHA256SUMS file pattern for verification:
#   1. Downloads terraform_<version>_SHA256SUMS and its signature (.sig)
#   2. Verifies the GPG signature of SHA256SUMS using HashiCorp's GPG key
#   3. Extracts the checksum for the specific file
#   4. Verifies the file checksum matches
#
# Arguments:
#   $1 - File to verify (e.g., "terraform_1.10.0_linux_amd64.zip")
#   $2 - Terraform version (e.g., "1.10.0")
#
# Returns:
#   0 on successful verification, 1 on failure
#
# Example:
#   download_and_verify_terraform_gpg "terraform_1.10.0_linux_amd64.zip" "1.10.0"
# ============================================================================
download_and_verify_terraform_gpg() {
    local file="$1"
    local version="$2"

    # Terraform SHA256SUMS URL
    local shasums_url="https://releases.hashicorp.com/terraform/${version}/terraform_${version}_SHA256SUMS"
    local shasums_file="${file%/*}/terraform_${version}_SHA256SUMS"

    log_message "Downloading Terraform checksums file..."
    if ! command curl -fsSL -o "$shasums_file" "$shasums_url" 2>/dev/null; then
        log_warning "Failed to download SHA256SUMS from ${shasums_url}"
        return 1
    fi

    # Download GPG signature (.sig file)
    local sig_url="${shasums_url}.sig"
    local signature_file="${shasums_file}.sig"

    log_message "Downloading GPG signature..."
    if ! command curl -fsSL -o "$signature_file" "$sig_url" 2>/dev/null; then
        log_warning "Failed to download GPG signature from ${sig_url}"
        command rm -f "$shasums_file"
        return 1
    fi

    log_message "Downloaded SHA256SUMS and signature"

    # Verify the GPG signature of SHA256SUMS
    log_message "Verifying GPG signature of SHA256SUMS..."
    if ! verify_gpg_signature "$shasums_file" "$signature_file" "hashicorp"; then
        log_error "GPG signature verification failed for SHA256SUMS"
        command rm -f "$shasums_file" "$signature_file"
        return 1
    fi

    log_message "GPG signature verified successfully"

    verify_file_against_shasums "$file" "$shasums_file" "$signature_file"
}

# Export function for use in other scripts
export -f download_and_verify_terraform_gpg
