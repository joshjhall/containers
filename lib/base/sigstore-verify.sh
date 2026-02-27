#!/bin/bash
# Sigstore/Cosign Signature Verification
#
# Provides Sigstore signature verification for language runtime downloads.
# Part of the signature verification system (see signature-verify.sh).
#
# Supported languages:
#   - Python 3.11.0+: Sigstore (separate .sig + .crt files)
#   - kubectl:        Sigstore (requires cosign from kubernetes or docker feature)
#
# Usage:
#   source /tmp/build-scripts/base/sigstore-verify.sh
#   verify_sigstore_signature "file.tar.gz" "file.tar.gz.sig" \
#     "user@example.org" "https://accounts.google.com" "file.tar.gz.crt"

# Prevent multiple sourcing
if [ -n "${_SIGSTORE_VERIFY_LOADED:-}" ]; then
    return 0
fi
_SIGSTORE_VERIFY_LOADED=1

set -euo pipefail

# Source logging utilities
if [ -f /tmp/build-scripts/base/logging.sh ]; then
    source /tmp/build-scripts/base/logging.sh
fi

# ============================================================================
# download_and_verify_kubectl_sigstore - Download and verify kubectl using Sigstore
#
# Kubernetes binaries are signed using Sigstore/cosign. This function downloads
# the binary's signature (.sig) and certificate (.cert) files and verifies them
# using cosign.
#
# Arguments:
#   $1 - Binary file path
#   $2 - Version (e.g., "1.28.0")
#
# Returns:
#   0 on successful verification, 1 on failure
#
# Example:
#   download_and_verify_kubectl_sigstore "/tmp/kubectl" "1.28.0"
#
# Note: Requires cosign to be installed
# ============================================================================
download_and_verify_kubectl_sigstore() {
    local file="$1"
    local version="$2"

    # Check if cosign is available
    if ! command -v cosign &> /dev/null; then
        log_warning "cosign not found, cannot verify kubectl Sigstore signature"
        log_warning "Install kubernetes or docker feature to get cosign"
        return 1
    fi

    local filename
    filename=$(basename "$file")

    # Kubectl signature files are hosted alongside the binary
    # For example: https://dl.k8s.io/release/v1.28.0/bin/linux/amd64/kubectl.sig
    local base_url
    base_url=$(dirname "$(grep -o 'https://dl.k8s.io/release/v[^/]*/bin/[^/]*/[^/]*' <<< "$file" 2>/dev/null || echo "")")

    if [ -z "$base_url" ]; then
        # Construct URL if not found in file path
        local arch
        case "$(uname -m)" in
            x86_64) arch="amd64" ;;
            aarch64) arch="arm64" ;;
            *) arch="amd64" ;;
        esac
        base_url="https://dl.k8s.io/release/v${version}/bin/linux/${arch}"
    fi

    local sig_url="${base_url}/${filename}.sig"
    local cert_url="${base_url}/${filename}.cert"
    local sig_file="${file}.sig"
    local cert_file="${file}.cert"

    # Download signature file
    log_message "Downloading kubectl Sigstore signature..."
    if ! command curl -fsSL -o "$sig_file" "$sig_url" 2>/dev/null; then
        log_warning "Failed to download signature from ${sig_url}"
        return 1
    fi

    # Download certificate file
    log_message "Downloading kubectl Sigstore certificate..."
    if ! command curl -fsSL -o "$cert_file" "$cert_url" 2>/dev/null; then
        log_warning "Failed to download certificate from ${cert_url}"
        command rm -f "$sig_file"
        return 1
    fi

    log_message "✓ Downloaded signature and certificate"

    # Verify using cosign
    # Kubernetes uses:
    #   - Certificate Identity: krel-staging@k8s-releng-prod.iam.gserviceaccount.com
    #   - OIDC Issuer: https://accounts.google.com
    log_message "Verifying kubectl binary with Sigstore/cosign..."

    if cosign verify-blob "$file" \
        --signature "$sig_file" \
        --certificate "$cert_file" \
        --certificate-identity "krel-staging@k8s-releng-prod.iam.gserviceaccount.com" \
        --certificate-oidc-issuer "https://accounts.google.com" \
        2>&1 | tee /tmp/cosign-verify.log; then

        log_message "✓ kubectl Sigstore verification successful"
        command rm -f "$sig_file" "$cert_file" /tmp/cosign-verify.log
        return 0
    else
        log_error "kubectl Sigstore verification failed"
        log_error "See /tmp/cosign-verify.log for details"
        command rm -f "$sig_file" "$cert_file"
        return 1
    fi
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

    # Build cosign args: separate .sig/.crt vs bundled .sigstore
    local -a cosign_args=(verify-blob)
    if [ -n "$cert_file" ]; then
        if [ ! -f "$cert_file" ]; then
            log_error "Certificate file not found: $cert_file"
            return 1
        fi
        log_message "  Using separate .sig and .crt files"
        cosign_args+=(--signature "$sig_or_bundle" --certificate "$cert_file")
    else
        log_message "  Using bundled .sigstore file"
        cosign_args+=(--bundle "$sig_or_bundle")
    fi
    cosign_args+=(--certificate-identity "$cert_identity" --certificate-oidc-issuer "$oidc_issuer" "$file")

    # Single verification path
    if cosign "${cosign_args[@]}" 2>&1 | tee /tmp/cosign-verify-output.txt | grep -q "Verified OK"; then
        log_message "✓ Sigstore signature verified successfully"
        log_message "  Cert Identity: $cert_identity"
        command rm -f /tmp/cosign-verify-output.txt
        return 0
    fi

    log_warning "Sigstore signature verification failed"
    if [ -f /tmp/cosign-verify-output.txt ]; then
        log_error "Cosign verification output:"
        command cat /tmp/cosign-verify-output.txt >&2
        command rm -f /tmp/cosign-verify-output.txt
    fi
    return 1
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

# Export all functions
export -f download_and_verify_kubectl_sigstore
export -f verify_sigstore_signature
export -f get_python_release_manager
export -f download_and_verify_sigstore
