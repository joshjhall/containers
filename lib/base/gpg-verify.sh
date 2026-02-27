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
            log_message "✓ GPG signature verified successfully"

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
        log_message "✓ Checksum verification passed"
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
    local filename
    filename=$(basename "$file")

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
            log_message "✓ Downloaded SHASUMS256.txt.${ext}"
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

    log_message "✓ GPG signature verified successfully"

    verify_file_against_shasums "$file" "$shasums_file" "$signature_file"
}

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
    local filename
    filename=$(basename "$file")

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

    log_message "✓ Downloaded SHA256SUMS and signature"

    # Verify the GPG signature of SHA256SUMS
    log_message "Verifying GPG signature of SHA256SUMS..."
    if ! verify_gpg_signature "$shasums_file" "$signature_file" "hashicorp"; then
        log_error "GPG signature verification failed for SHA256SUMS"
        command rm -f "$shasums_file" "$signature_file"
        return 1
    fi

    log_message "✓ GPG signature verified successfully"

    verify_file_against_shasums "$file" "$shasums_file" "$signature_file"
}

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
    local version="$2"
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

    log_message "✓ Downloaded GPG signature"

    # Verify the GPG signature
    log_message "Verifying GPG signature..."
    if ! verify_gpg_signature "$file" "$signature_file" "golang"; then
        log_error "GPG signature verification failed"
        command rm -f "$signature_file"
        return 1
    fi

    log_message "✓ GPG signature verified successfully"
    command rm -f "$signature_file"
    return 0
}

# Export all functions
export -f import_gpg_keys
export -f verify_gpg_signature
export -f download_and_verify_gpg
export -f verify_file_against_shasums
export -f download_and_verify_nodejs_gpg
export -f download_and_verify_terraform_gpg
export -f download_and_verify_golang_gpg
