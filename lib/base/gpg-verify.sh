#!/bin/bash
# GPG Signature Verification
#
# Provides GPG/PGP signature verification for language runtime downloads.
# Part of the signature verification system (see signature-verify.sh).
#
# Supported languages:
#   - Python:    GPG (.asc signatures via release manager keys)
#   - Node.js:   GPG (SHASUMS256.txt.sig or .asc)
#   - Go:        GPG (.asc signatures via Google signing key)
#   - Terraform: GPG (SHA256SUMS.sig via HashiCorp key)
#
# Usage:
#   source /tmp/build-scripts/base/gpg-verify.sh
#   verify_gpg_signature "file.tar.gz" "file.tar.gz.asc" "python"

# Prevent multiple sourcing
if [ -n "${_GPG_VERIFY_LOADED:-}" ]; then
    return 0
fi
_GPG_VERIFY_LOADED=1

set -euo pipefail

# Source logging utilities
if [ -f /tmp/build-scripts/base/logging.sh ]; then
    source /tmp/build-scripts/base/logging.sh
fi

# GPG keyring directory (can be overridden for testing)
GPG_KEYRING_DIR="${GPG_KEYRING_DIR:-/tmp/build-scripts/gpg-keys}"

# ============================================================================
# import_gpg_keys - Import GPG keys for a language from keyring directory
#
# Arguments:
#   $1 - Language name (e.g., "python", "nodejs", "rust")
#
# Returns:
#   0 on success, 1 if no keys found or import failed
#
# Example:
#   import_gpg_keys "python"
#
# Supports two keyring formats:
#   1. Individual key files: keys/*.asc, keys/*.gpg (Python style)
#   2. GPG keyring directory: keyring/pubring.kbx + trustdb.gpg (Node.js style)
# ============================================================================
import_gpg_keys() {
    local language="$1"
    local keyring_path="${GPG_KEYRING_DIR}/${language}"

    if [ ! -d "$keyring_path" ]; then
        log_message "No GPG keyring found for ${language} at ${keyring_path}"
        return 1
    fi

    # Check if there's a keyring subdirectory (Node.js style)
    if [ -d "${keyring_path}/keyring" ] && [ -f "${keyring_path}/keyring/pubring.kbx" ]; then
        log_message "Using GPG keyring directory for ${language}"

        # Export GNUPGHOME to use this keyring for verification
        export GNUPGHOME="${keyring_path}/keyring"

        # Verify keyring is readable
        if ! gpg --list-keys >/dev/null 2>&1; then
            log_error "Failed to read GPG keyring for ${language}"
            return 1
        fi

        local key_count
        key_count=$(gpg --list-keys 2>/dev/null | grep -c "^pub" || echo "0")
        log_message "Using keyring with ${key_count} GPG keys for ${language}"
        return 0
    fi

    # Otherwise, import individual key files (Python style)
    # Check for keys in a 'keys/' subdirectory first, then fall back to root
    local keys_dir="${keyring_path}"
    if [ -d "${keyring_path}/keys" ]; then
        keys_dir="${keyring_path}/keys"
        log_message "Using individual GPG keys from ${language}/keys/"
    fi

    local key_count=0
    local imported_count=0

    # Import all .asc and .gpg files from the keys directory
    for ext in asc gpg; do
        for key_file in "${keys_dir}"/*."${ext}"; do
            [ -f "$key_file" ] || continue

            key_count=$((key_count + 1))

            if gpg --import "$key_file" 2>/dev/null; then
                imported_count=$((imported_count + 1))
                log_message "Imported GPG key: $(basename "$key_file")"
            else
                log_warning "Failed to import GPG key: $(basename "$key_file")"
            fi
        done
    done

    if [ "$key_count" -eq 0 ]; then
        log_message "No GPG key files found in ${keyring_path}"
        return 1
    fi

    if [ "$imported_count" -eq 0 ]; then
        log_error "Failed to import any GPG keys for ${language}"
        return 1
    fi

    log_message "Imported ${imported_count}/${key_count} GPG keys for ${language}"
    return 0
}

# ============================================================================
# verify_gpg_signature - Verify GPG signature of a downloaded file
#
# Arguments:
#   $1 - File to verify
#   $2 - Signature file (.asc or .sig)
#   $3 - Language name (for keyring lookup)
#
# Returns:
#   0 on successful verification, 1 on failure
#
# Example:
#   verify_gpg_signature "Python-3.12.7.tar.gz" "Python-3.12.7.tar.gz.asc" "python"
# ============================================================================
verify_gpg_signature() {
    local file="$1"
    local signature_file="$2"
    local language="$3"

    if [ ! -f "$file" ]; then
        log_error "File not found for GPG verification: $file"
        return 1
    fi

    if [ ! -f "$signature_file" ]; then
        log_error "Signature file not found: $signature_file"
        return 1
    fi

    # Import keys for this language (idempotent - safe to call multiple times)
    import_gpg_keys "$language" || {
        log_warning "Could not import GPG keys for ${language}"
        return 1
    }

    # Verify the signature
    log_message "Verifying GPG signature for $(basename "$file")..."

    if gpg --verify "$signature_file" "$file" 2>&1 | tee /tmp/gpg-verify-output.txt; then
        # Check if verification was successful
        if grep -q "Good signature" /tmp/gpg-verify-output.txt; then
            log_message "GPG signature verified successfully"

            # Extract signer information
            local signer
            signer=$(grep "Good signature from" /tmp/gpg-verify-output.txt | head -1)
            if [ -n "$signer" ]; then
                log_message "  Signer: ${signer#*Good signature from }"
            fi

            command rm -f /tmp/gpg-verify-output.txt
            return 0
        fi
    fi

    log_error "GPG signature verification failed"

    # Show verification output for debugging
    if [ -f /tmp/gpg-verify-output.txt ]; then
        log_error "GPG verification output:"
        command cat /tmp/gpg-verify-output.txt >&2
        command rm -f /tmp/gpg-verify-output.txt
    fi

    return 1
}

# ============================================================================
# download_and_verify_gpg - Download signature file and verify
#
# Arguments:
#   $1 - File to verify
#   $2 - Signature URL (if not provided, tries common patterns)
#   $3 - Language name
#
# Returns:
#   0 on successful verification, 1 on failure
#
# Example:
#   download_and_verify_gpg "Python-3.12.7.tar.gz" "" "python"
# ============================================================================
download_and_verify_gpg() {
    local file="$1"
    local signature_url="${2:-}"
    local language="$3"

    local signature_file="${file}.asc"

    # If signature URL not provided, try common patterns
    if [ -z "$signature_url" ]; then
        log_message "No signature URL provided, will try common patterns"
        return 1
    fi

    # Download signature file
    log_message "Downloading GPG signature from ${signature_url}..."

    if ! command curl -fsSL -o "$signature_file" "$signature_url" 2>/dev/null; then
        log_warning "Failed to download GPG signature from ${signature_url}"
        return 1
    fi

    # Verify the signature
    verify_gpg_signature "$file" "$signature_file" "$language"
    local result=$?

    # Clean up signature file
    command rm -f "$signature_file"

    return $result
}

# ============================================================================
# verify_file_against_shasums - Verify a file's checksum against a SHASUMS file
#
# Shared logic used by Node.js and Terraform GPG verification. Extracts the
# expected checksum for a specific file from a SHASUMS file, calculates the
# actual checksum, and compares them. Cleans up shasums/sig files on completion.
#
# Arguments:
#   $1 - File to verify
#   $2 - SHASUMS file path
#   $3 - Signature file path (cleaned up along with shasums)
#
# Returns:
#   0 on match, 1 on mismatch or missing entry
# ============================================================================
verify_file_against_shasums() {
    local file="$1"
    local shasums_file="$2"
    local signature_file="$3"
    local filename
    filename=$(basename "$file")

    log_message "Extracting checksum for ${filename}..."
    local expected_checksum
    expected_checksum=$(grep "${filename}" "$shasums_file" | awk '{print $1}')

    if [ -z "$expected_checksum" ]; then
        log_error "File ${filename} not found in $(basename "$shasums_file")"
        command rm -f "$shasums_file" "$signature_file"
        return 1
    fi

    log_message "Expected checksum: ${expected_checksum}"

    local actual_checksum
    actual_checksum=$(sha256sum "$file" | awk '{print $1}')
    log_message "Actual checksum:   ${actual_checksum}"

    if [ "$actual_checksum" = "$expected_checksum" ]; then
        log_message "Checksum verification passed"
        command rm -f "$shasums_file" "$signature_file"
        return 0
    else
        log_error "Checksum mismatch!"
        log_error "Expected: ${expected_checksum}"
        log_error "Got:      ${actual_checksum}"
        command rm -f "$shasums_file" "$signature_file"
        return 1
    fi
}

# ============================================================================
# Source sub-modules
# ============================================================================
_GPG_VERIFY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_GPG_VERIFY_DIR}/gpg-verify-nodejs.sh"
source "${_GPG_VERIFY_DIR}/gpg-verify-terraform.sh"
source "${_GPG_VERIFY_DIR}/gpg-verify-golang.sh"

# Export all functions
export -f import_gpg_keys
export -f verify_gpg_signature
export -f download_and_verify_gpg
export -f verify_file_against_shasums
