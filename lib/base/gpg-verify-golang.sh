#!/bin/bash
# Go GPG Verification
#
# Provides download_and_verify_golang_gpg() for Go-specific GPG verification.
# Part of the GPG verification system (see gpg-verify.sh).
#
# Usage:
#   source /tmp/build-scripts/base/gpg-verify.sh  # Sources this automatically
#   download_and_verify_golang_gpg "go1.23.4.linux-amd64.tar.gz" "1.23.4"

# Prevent multiple sourcing
if [ -n "${_GPG_VERIFY_GOLANG_LOADED:-}" ]; then
    return 0
fi
_GPG_VERIFY_GOLANG_LOADED=1

# ============================================================================
# download_and_verify_golang_gpg - Go-specific GPG verification
#
# Go releases include .asc signature files that can be verified using
# Google's Linux Packages Signing Key.
#
# Arguments:
#   $1 - File to verify (e.g., "go1.23.4.linux-amd64.tar.gz")
#   $2 - Go version (e.g., "1.23.4")
#
# Returns:
#   0 on successful verification, 1 on failure
#
# Example:
#   download_and_verify_golang_gpg "go1.23.4.linux-amd64.tar.gz" "1.23.4"
# ============================================================================
download_and_verify_golang_gpg() {
    local file="$1"
    # $2 (version) reserved for API consistency with other verify functions
    local filename
    filename=$(basename "$file")

    # Go signature URL
    local sig_url="https://go.dev/dl/${filename}.asc"
    local signature_file="${file}.asc"

    log_message "Downloading Go GPG signature..."
    if ! command curl -fsSL -o "$signature_file" "$sig_url" 2>/dev/null; then
        log_warning "Failed to download GPG signature from ${sig_url}"
        return 1
    fi

    log_message "Downloaded GPG signature"

    # Verify the GPG signature
    log_message "Verifying GPG signature..."
    if ! verify_gpg_signature "$file" "$signature_file" "golang"; then
        log_error "GPG signature verification failed"
        command rm -f "$signature_file"
        return 1
    fi

    log_message "GPG signature verified successfully"
    command rm -f "$signature_file"
    return 0
}

# Export function for use in other scripts
export -f download_and_verify_golang_gpg
