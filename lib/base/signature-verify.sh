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
# Sigstore Verification Functions
# ============================================================================

# ============================================================================
# verify_sigstore_signature - Verify Sigstore signature using cosign
#
# Supports both bundle format and separate signature/certificate files.
# Python uses separate .sig and .crt files, not the bundled .sigstore format.
#
# Arguments:
#   $1 - File to verify
#   $2 - Signature file (.sig) or bundle file (.sigstore)
#   $3 - Certificate identity (e.g., release manager email)
#   $4 - OIDC issuer URL
#   $5 - Optional: Certificate file (.crt) if using separate files
#
# Returns:
#   0 on successful verification, 1 on failure
#
# Example (bundle format):
#   verify_sigstore_signature "file.tar.gz" "file.tar.gz.sigstore" \
#     "user@example.org" "https://accounts.google.com"
#
# Example (separate files - Python format):
#   verify_sigstore_signature "Python-3.12.0.tar.gz" "Python-3.12.0.tar.gz.sig" \
#     "thomas@python.org" "https://accounts.google.com" "Python-3.12.0.tar.gz.crt"
# ============================================================================
verify_sigstore_signature() {
    local file="$1"
    local sig_or_bundle="$2"
    local cert_identity="$3"
    local oidc_issuer="$4"
    local cert_file="${5:-}"

    # Check if cosign is available
    if ! command -v cosign >/dev/null 2>&1; then
        log_message "Sigstore verification unavailable: cosign not installed"
        return 1
    fi

    if [ ! -f "$file" ]; then
        log_error "File not found for Sigstore verification: $file"
        return 1
    fi

    if [ ! -f "$sig_or_bundle" ]; then
        log_error "Signature/bundle file not found: $sig_or_bundle"
        return 1
    fi

    log_message "Verifying Sigstore signature for $(basename "$file")..."

    # Determine format based on whether cert_file is provided
    if [ -n "$cert_file" ]; then
        # Separate signature and certificate files (Python format)
        if [ ! -f "$cert_file" ]; then
            log_error "Certificate file not found: $cert_file"
            return 1
        fi

        log_message "  Using separate .sig and .crt files"

        # Verify using separate files
        if cosign verify-blob \
            --signature "$sig_or_bundle" \
            --certificate "$cert_file" \
            --certificate-identity "$cert_identity" \
            --certificate-oidc-issuer "$oidc_issuer" \
            "$file" 2>&1 | tee /tmp/cosign-verify-output.txt | grep -q "Verified OK"; then

            log_message "✓ Sigstore signature verified successfully"
            log_message "  Cert Identity: $cert_identity"
            command rm -f /tmp/cosign-verify-output.txt
            return 0
        else
            log_warning "Sigstore signature verification failed"

            # Show verification output for debugging
            if [ -f /tmp/cosign-verify-output.txt ]; then
                log_error "Cosign verification output:"
                command cat /tmp/cosign-verify-output.txt >&2
                command rm -f /tmp/cosign-verify-output.txt
            fi
            return 1
        fi
    else
        # Bundle format (.sigstore file)
        log_message "  Using bundled .sigstore file"

        # Verify using bundle
        if cosign verify-blob \
            --bundle "$sig_or_bundle" \
            --certificate-identity "$cert_identity" \
            --certificate-oidc-issuer "$oidc_issuer" \
            "$file" 2>&1 | tee /tmp/cosign-verify-output.txt | grep -q "Verified OK"; then

            log_message "✓ Sigstore signature verified successfully"
            log_message "  Cert Identity: $cert_identity"
            command rm -f /tmp/cosign-verify-output.txt
            return 0
        else
            log_warning "Sigstore signature verification failed"

            # Show verification output for debugging
            if [ -f /tmp/cosign-verify-output.txt ]; then
                log_error "Cosign verification output:"
                command cat /tmp/cosign-verify-output.txt >&2
                command rm -f /tmp/cosign-verify-output.txt
            fi
            return 1
        fi
    fi
}

# ============================================================================
# get_python_release_manager - Get release manager info for Python version
#
# Arguments:
#   $1 - Python version (e.g., "3.12.0")
#
# Outputs:
#   Two lines: certificate identity, then OIDC issuer
#
# Returns:
#   0 on success, 1 if version mapping not found
#
# Based on: https://www.python.org/downloads/metadata/sigstore/
# ============================================================================
get_python_release_manager() {
    local version="$1"
    local major minor
    IFS='.' read -r major minor _ <<< "$version"

    # Only Python 3.x is supported
    if [ "$major" != "3" ]; then
        return 1
    fi

    # Map minor version to release manager
    # Source: https://www.python.org/downloads/metadata/sigstore/
    case "$minor" in
        7)
            echo "nad@python.org"
            echo "https://github.com/login/oauth"
            ;;
        8|9)
            echo "lukasz@langa.pl"
            echo "https://github.com/login/oauth"
            ;;
        10|11)
            echo "pablogsal@python.org"
            echo "https://accounts.google.com"
            ;;
        12|13)
            echo "thomas@python.org"
            echo "https://accounts.google.com"
            ;;
        14|15)
            echo "hugo@python.org"
            echo "https://github.com/login/oauth"
            ;;
        16|17)
            echo "savannah@python.org"
            echo "https://github.com/login/oauth"
            ;;
        *)
            # Unknown version - return error
            return 1
            ;;
    esac
    return 0
}

# ============================================================================
# download_and_verify_sigstore - Download Sigstore files and verify
#
# Supports both bundle format (.sigstore) and separate files (.sig + .crt).
# Python uses separate .sig and .crt files.
#
# Arguments:
#   $1 - File to verify
#   $2 - Sigstore signature URL (can be .sigstore bundle or .sig file)
#   $3 - Certificate identity
#   $4 - OIDC issuer URL
#   $5 - Optional: Certificate URL (.crt file) for separate file format
#
# Returns:
#   0 on successful verification, 1 on failure
# ============================================================================
download_and_verify_sigstore() {
    local file="$1"
    local sig_url="$2"
    local cert_identity="$3"
    local oidc_issuer="$4"
    local cert_url="${5:-}"

    local sig_file cert_file

    # Check if using separate files (Python format) or bundle
    if [ -n "$cert_url" ]; then
        # Separate .sig and .crt files
        sig_file="${file}.sig"
        cert_file="${file}.crt"

        # Download signature file
        log_message "Downloading Sigstore signature from ${sig_url}..."
        if ! command curl -fsSL -o "$sig_file" "$sig_url" 2>/dev/null; then
            log_warning "Failed to download Sigstore signature from ${sig_url}"
            return 1
        fi

        # Download certificate file
        log_message "Downloading Sigstore certificate from ${cert_url}..."
        if ! command curl -fsSL -o "$cert_file" "$cert_url" 2>/dev/null; then
            log_warning "Failed to download Sigstore certificate from ${cert_url}"
            command rm -f "$sig_file"
            return 1
        fi

        # Verify the signature with separate files
        verify_sigstore_signature "$file" "$sig_file" "$cert_identity" "$oidc_issuer" "$cert_file"
        local result=$?

        # Clean up files
        command rm -f "$sig_file" "$cert_file"

        return $result
    else
        # Bundle format (.sigstore file)
        local bundle_file="${file}.sigstore"

        # Download bundle file
        log_message "Downloading Sigstore bundle from ${sig_url}..."
        if ! command curl -fsSL -o "$bundle_file" "$sig_url" 2>/dev/null; then
            log_warning "Failed to download Sigstore bundle from ${sig_url}"
            return 1
        fi

        # Verify the signature with bundle
        verify_sigstore_signature "$file" "$bundle_file" "$cert_identity" "$oidc_issuer"
        local result=$?

        # Clean up bundle file
        command rm -f "$bundle_file"

        return $result
    fi
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
        local major minor
        IFS='.' read -r major minor _ <<< "$version"

        # Check if version >= 3.11.0
        if [ "$major" -ge 3 ] && [ "$minor" -ge 11 ]; then
            log_message "Python ${version} supports Sigstore, trying Sigstore first..."

            if command -v cosign >/dev/null 2>&1; then
                # Get release manager information
                local cert_identity oidc_issuer
                if ! cert_identity=$(get_python_release_manager "$version" | head -1); then
                    log_warning "Could not determine release manager for Python ${version}"
                    log_message "Falling back to GPG verification"
                else
                    oidc_issuer=$(get_python_release_manager "$version" | tail -1)

                    # Construct Sigstore URLs (Python uses separate .sig and .crt files)
                    # Format: https://www.python.org/ftp/python/{version}/Python-{version}.tar.xz.sig
                    #         https://www.python.org/ftp/python/{version}/Python-{version}.tar.xz.crt
                    local sig_url cert_url
                    sig_url="https://www.python.org/ftp/python/${version}/$(basename "$file").sig"
                    cert_url="https://www.python.org/ftp/python/${version}/$(basename "$file").crt"

                    log_message "Attempting Sigstore verification..."
                    log_message "  Certificate Identity: ${cert_identity}"
                    log_message "  OIDC Issuer: ${oidc_issuer}"

                    # Try Sigstore verification with separate .sig and .crt files
                    if download_and_verify_sigstore "$file" "$sig_url" "$cert_identity" "$oidc_issuer" "$cert_url"; then
                        log_message "✓ Sigstore verification successful"
                        return 0
                    else
                        log_warning "Sigstore verification failed, falling back to GPG"
                    fi
                fi
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
export -f get_python_release_manager
export -f download_and_verify_sigstore
export -f verify_signature
