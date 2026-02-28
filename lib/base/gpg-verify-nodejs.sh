#!/bin/bash
# Node.js GPG Verification
#
# Provides download_and_verify_nodejs_gpg() for Node.js-specific GPG verification.
# Part of the GPG verification system (see gpg-verify.sh).
#
# Usage:
#   source /tmp/build-scripts/base/gpg-verify.sh  # Sources this automatically
#   download_and_verify_nodejs_gpg "node-v20.18.0-linux-x64.tar.xz" "20.18.0"

# Prevent multiple sourcing
if [ -n "${_GPG_VERIFY_NODEJS_LOADED:-}" ]; then
    return 0
fi
_GPG_VERIFY_NODEJS_LOADED=1

# ============================================================================
# download_and_verify_nodejs_gpg - Node.js-specific GPG verification
#
# Node.js uses a SHASUMS256.txt file with a GPG signature, rather than
# per-file signatures. This function:
#   1. Downloads SHASUMS256.txt and its signature (.sig or .asc)
#   2. Verifies the GPG signature of SHASUMS256.txt
#   3. Extracts the checksum for the specific file
#   4. Verifies the file checksum matches
#
# Arguments:
#   $1 - File to verify (e.g., "node-v20.18.0-linux-x64.tar.xz")
#   $2 - Node.js version (e.g., "20.18.0")
#
# Returns:
#   0 on successful verification, 1 on failure
#
# Example:
#   download_and_verify_nodejs_gpg "node-v20.18.0-linux-x64.tar.xz" "20.18.0"
# ============================================================================
download_and_verify_nodejs_gpg() {
    local file="$1"
    local version="$2"

    # Node.js SHASUMS256.txt URL
    local shasums_url="https://nodejs.org/dist/v${version}/SHASUMS256.txt"
    local shasums_file="${file%/*}/SHASUMS256.txt"

    log_message "Downloading Node.js checksums file..."
    if ! command curl -fsSL -o "$shasums_file" "$shasums_url" 2>/dev/null; then
        log_warning "Failed to download SHASUMS256.txt from ${shasums_url}"
        return 1
    fi

    # Try .sig first (binary signature), then .asc (ASCII-armored)
    local signature_file=""
    local sig_url=""

    for ext in sig asc; do
        sig_url="${shasums_url}.${ext}"
        signature_file="${shasums_file}.${ext}"

        log_message "Attempting to download SHASUMS256.txt.${ext}..."
        if command curl -fsSL -o "$signature_file" "$sig_url" 2>/dev/null; then
            log_message "Downloaded SHASUMS256.txt.${ext}"
            break
        else
            log_message "  SHASUMS256.txt.${ext} not available"
            signature_file=""
        fi
    done

    if [ -z "$signature_file" ] || [ ! -f "$signature_file" ]; then
        log_warning "Failed to download Node.js GPG signature (.sig or .asc)"
        command rm -f "$shasums_file"
        return 1
    fi

    # Verify the GPG signature of SHASUMS256.txt
    log_message "Verifying GPG signature of SHASUMS256.txt..."
    if ! verify_gpg_signature "$shasums_file" "$signature_file" "nodejs"; then
        log_error "GPG signature verification failed for SHASUMS256.txt"
        command rm -f "$shasums_file" "$signature_file"
        return 1
    fi

    log_message "GPG signature verified successfully"

    verify_file_against_shasums "$file" "$shasums_file" "$signature_file"
}

# Export function for use in other scripts
export -f download_and_verify_nodejs_gpg
