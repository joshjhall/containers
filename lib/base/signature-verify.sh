#!/bin/bash
# Signature Verification System (GPG + Sigstore)
#
# Provides cryptographic signature verification for language runtime downloads.
# Supports both GPG/PGP and Sigstore signatures.
# Used as Tier 1 in the 4-tier checksum verification system.
#
# Signature Support by Language:
#   - Python 3.11.0+:  Sigstore (preferred) + GPG (fallback)
#   - Python < 3.11.0: GPG only
#   - All others:      GPG only (where available)
#
# Usage:
#   source /tmp/build-scripts/base/signature-verify.sh
#   verify_signature "file.tar.gz" "python" "3.12.0"
#
# Returns:
#   0 if signature verified successfully
#   1 if signature verification failed or unavailable

set -euo pipefail

# Source logging utilities
if [ -f /tmp/build-scripts/base/logging.sh ]; then
    source /tmp/build-scripts/base/logging.sh
fi

# GPG keyring directory
GPG_KEYRING_DIR="/tmp/build-scripts/gpg-keys"

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
# ============================================================================
import_gpg_keys() {
    local language="$1"
    local keyring_path="${GPG_KEYRING_DIR}/${language}"

    if [ ! -d "$keyring_path" ]; then
        log_message "No GPG keyring found for ${language} at ${keyring_path}"
        return 1
    fi

    local key_count=0
    local imported_count=0

    # Import all .asc and .gpg files from the keyring directory
    for ext in asc gpg; do
        for key_file in "${keyring_path}"/*."${ext}"; do
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

            rm -f /tmp/gpg-verify-output.txt
            return 0
        fi
    fi

    log_error "GPG signature verification failed"

    # Show verification output for debugging
    if [ -f /tmp/gpg-verify-output.txt ]; then
        log_error "GPG verification output:"
        cat /tmp/gpg-verify-output.txt >&2
        rm -f /tmp/gpg-verify-output.txt
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

    if ! curl -fsSL -o "$signature_file" "$signature_url" 2>/dev/null; then
        log_warning "Failed to download GPG signature from ${signature_url}"
        return 1
    fi

    # Verify the signature
    verify_gpg_signature "$file" "$signature_file" "$language"
    local result=$?

    # Clean up signature file
    rm -f "$signature_file"

    return $result
}

# ============================================================================
# Sigstore Verification Functions
# ============================================================================

# ============================================================================
# verify_sigstore_signature - Verify Sigstore signature using cosign
#
# Arguments:
#   $1 - File to verify
#   $2 - Sigstore bundle file (.sigstore)
#   $3 - Certificate identity (e.g., release manager email)
#   $4 - OIDC issuer URL
#
# Returns:
#   0 on successful verification, 1 on failure
#
# Example:
#   verify_sigstore_signature "Python-3.12.0.tar.gz" "Python-3.12.0.tar.gz.sigstore" \
#     "thomas@python.org" "https://accounts.google.com"
# ============================================================================
verify_sigstore_signature() {
    local file="$1"
    local bundle_file="$2"
    local cert_identity="$3"
    local oidc_issuer="$4"

    # Check if cosign is available
    if ! command -v cosign >/dev/null 2>&1; then
        log_message "Sigstore verification unavailable: cosign not installed"
        return 1
    fi

    if [ ! -f "$file" ]; then
        log_error "File not found for Sigstore verification: $file"
        return 1
    fi

    if [ ! -f "$bundle_file" ]; then
        log_error "Sigstore bundle not found: $bundle_file"
        return 1
    fi

    log_message "Verifying Sigstore signature for $(basename "$file")..."

    # Verify using cosign
    if cosign verify-blob \
        --bundle "$bundle_file" \
        --certificate-identity "$cert_identity" \
        --certificate-oidc-issuer "$oidc_issuer" \
        "$file" >/dev/null 2>&1; then

        log_message "✓ Sigstore signature verified successfully"
        log_message "  Cert Identity: $cert_identity"
        return 0
    else
        log_warning "Sigstore signature verification failed"
        return 1
    fi
}

# ============================================================================
# download_and_verify_sigstore - Download Sigstore bundle and verify
#
# Arguments:
#   $1 - File to verify
#   $2 - Sigstore bundle URL
#   $3 - Certificate identity
#   $4 - OIDC issuer URL
#
# Returns:
#   0 on successful verification, 1 on failure
# ============================================================================
download_and_verify_sigstore() {
    local file="$1"
    local bundle_url="$2"
    local cert_identity="$3"
    local oidc_issuer="$4"

    local bundle_file="${file}.sigstore"

    # Download bundle file
    log_message "Downloading Sigstore bundle from ${bundle_url}..."

    if ! curl -fsSL -o "$bundle_file" "$bundle_url" 2>/dev/null; then
        log_warning "Failed to download Sigstore bundle from ${bundle_url}"
        return 1
    fi

    # Verify the signature
    verify_sigstore_signature "$file" "$bundle_file" "$cert_identity" "$oidc_issuer"
    local result=$?

    # Clean up bundle file
    rm -f "$bundle_file"

    return $result
}

# ============================================================================
# Unified Signature Verification
# ============================================================================

# ============================================================================
# verify_signature - Unified signature verification (Sigstore + GPG)
#
# Automatically chooses the appropriate verification method based on:
#   - Language
#   - Version
#   - Available tools (cosign, gpg)
#   - Available signature files
#
# Arguments:
#   $1 - File to verify
#   $2 - Language (python, nodejs, rust, ruby, golang, java)
#   $3 - Version (e.g., "3.12.0")
#   $4 - Optional: Signature URL (auto-detected if not provided)
#
# Returns:
#   0 on successful verification
#   1 if verification failed or unavailable
#
# Example:
#   verify_signature "Python-3.12.0.tar.gz" "python" "3.12.0"
# ============================================================================
verify_signature() {
    local file="$1"
    local language="$2"
    local version="$3"
    local signature_url="${4:-}"

    log_message "Attempting Tier 1: Signature verification (Sigstore/GPG)"

    # Python-specific logic: Try Sigstore first for 3.11.0+
    if [ "$language" = "python" ]; then
        local major minor patch
        IFS='.' read -r major minor patch <<< "$version"

        # Check if version >= 3.11.0
        if [ "$major" -ge 3 ] && [ "$minor" -ge 11 ]; then
            log_message "Python ${version} supports Sigstore, trying Sigstore first..."

            if command -v cosign >/dev/null 2>&1; then
                # Try to download and verify Sigstore bundle
                local base_url="https://www.python.org/ftp/python/${version}"
                local sigstore_url="${base_url}/$(basename "$file").sigstore"

                # TODO: Need to determine cert identity and OIDC issuer based on version
                # For now, log that Sigstore is available but needs configuration
                log_message "Sigstore available but requires release manager configuration"
                log_message "Falling back to GPG verification"
            else
                log_message "Cosign not available, skipping Sigstore verification"
            fi
        fi
    fi

    # Try GPG verification for all languages (fallback for Python, primary for others)
    log_message "Attempting GPG verification..."

    # Try to auto-detect GPG signature URL if not provided
    if [ -z "$signature_url" ]; then
        case "$language" in
            python)
                signature_url="https://www.python.org/ftp/python/${version}/$(basename "$file").asc"
                ;;
            # Add other languages as GPG support is implemented
        esac
    fi

    if [ -n "$signature_url" ]; then
        if download_and_verify_gpg "$file" "$signature_url" "$language"; then
            return 0
        fi
    fi

    log_message "Tier 1 (signature verification) unavailable or failed, will fallback to Tier 2"
    return 1
}

# Export all functions
export -f import_gpg_keys
export -f verify_gpg_signature
export -f download_and_verify_gpg
export -f verify_sigstore_signature
export -f download_and_verify_sigstore
export -f verify_signature
