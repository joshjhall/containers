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
#   - Node.js:         GPG (SHASUMS256.txt.sig or .asc)
#   - Go (Golang):     GPG (.asc signatures via Google signing key)
#   - Terraform:       GPG (terraform_<version>_SHA256SUMS.sig via HashiCorp key)
#   - kubectl:         Sigstore (requires cosign from kubernetes or docker feature)
#   - All others:      GPG only (where available)
#
# Usage:
#   source /tmp/build-scripts/base/signature-verify.sh
#   verify_signature "file.tar.gz" "python" "3.12.0"
#
# Returns:
#   0 if signature verified successfully
#   1 if signature verification failed or unavailable

# Prevent multiple sourcing
if [ -n "${_SIGNATURE_VERIFY_LOADED:-}" ]; then
    return 0
fi
_SIGNATURE_VERIFY_LOADED=1

set -euo pipefail

# Source logging utilities
if [ -f /tmp/build-scripts/base/logging.sh ]; then
    source /tmp/build-scripts/base/logging.sh
fi

# Source GPG and Sigstore verification modules
SIGNATURE_VERIFY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SIGNATURE_VERIFY_DIR}/gpg-verify.sh"
source "${SIGNATURE_VERIFY_DIR}/sigstore-verify.sh"

# ============================================================================
# Unified Signature Verification
# ============================================================================

# ============================================================================
# _verify_language_handler - Dispatch to per-language signature verification
#
# Handles languages with straightforward single-method verification.
# Python is NOT dispatched here because it has Sigstore-first + GPG fallback.
#
# Arguments:
#   $1 - Language name
#   $2 - File to verify
#   $3 - Version
#
# Returns:
#   0 on successful verification, 1 on failure, 2 if language not handled
# ============================================================================
_verify_language_handler() {
    local language="$1" file="$2" version="$3"
    case "$language" in
        nodejs)
            log_message "Node.js detected, using SHASUMS-based GPG verification..."
            download_and_verify_nodejs_gpg "$file" "$version"
            ;;
        kubectl|kubernetes)
            log_message "kubectl detected, using Sigstore verification..."
            download_and_verify_kubectl_sigstore "$file" "$version"
            ;;
        terraform)
            log_message "Terraform detected, using HashiCorp SHA256SUMS GPG verification..."
            download_and_verify_terraform_gpg "$file" "$version"
            ;;
        golang|go)
            log_message "Go detected, using GPG .asc signature verification..."
            download_and_verify_golang_gpg "$file" "$version"
            ;;
        *)
            return 2
            ;;
    esac
}

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

    # Python-specific logic: Try Sigstore first for 3.11.0+, then fall through to GPG
    if [ "$language" = "python" ]; then
        local major minor
        IFS='.' read -r major minor _ <<< "$version"

        if [ "$major" -ge 3 ] && [ "$minor" -ge 11 ]; then
            log_message "Python ${version} supports Sigstore, trying Sigstore first..."

            if command -v cosign >/dev/null 2>&1; then
                local cert_identity oidc_issuer
                if ! cert_identity=$(get_python_release_manager "$version" | command head -1); then
                    log_warning "Could not determine release manager for Python ${version}"
                    log_message "Falling back to GPG verification"
                else
                    oidc_issuer=$(get_python_release_manager "$version" | command tail -1)

                    local sig_url cert_url
                    sig_url="https://www.python.org/ftp/python/${version}/$(basename "$file").sig"
                    cert_url="https://www.python.org/ftp/python/${version}/$(basename "$file").crt"

                    log_message "Attempting Sigstore verification..."
                    log_message "  Certificate Identity: ${cert_identity}"
                    log_message "  OIDC Issuer: ${oidc_issuer}"

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

    # Dispatch to per-language handler (nodejs, kubectl, terraform, golang)
    local handler_result=0
    _verify_language_handler "$language" "$file" "$version" || handler_result=$?
    if [ "$handler_result" -eq 0 ]; then
        log_message "✓ ${language} signature verification successful"
        return 0
    elif [ "$handler_result" -eq 1 ]; then
        log_warning "${language} signature verification failed"
    fi
    # handler_result == 2 means language not handled, fall through to GPG

    # Try GPG verification (fallback for Python, primary for unhandled languages)
    log_message "Attempting GPG verification..."

    if [ -z "$signature_url" ]; then
        case "$language" in
            python)
                signature_url="https://www.python.org/ftp/python/${version}/$(basename "$file").asc"
                ;;
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

# Export dispatch functions
export -f _verify_language_handler
export -f verify_signature
