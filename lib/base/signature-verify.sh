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
                if ! cert_identity=$(get_python_release_manager "$version" | head -1); then
                    log_warning "Could not determine release manager for Python ${version}"
                    log_message "Falling back to GPG verification"
                else
                    oidc_issuer=$(get_python_release_manager "$version" | tail -1)

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

# Export all functions
export -f import_gpg_keys
export -f verify_gpg_signature
export -f download_and_verify_gpg
export -f download_and_verify_nodejs_gpg
export -f download_and_verify_terraform_gpg
export -f download_and_verify_golang_gpg
export -f download_and_verify_kubectl_sigstore
export -f verify_sigstore_signature
export -f get_python_release_manager
export -f download_and_verify_sigstore
export -f _verify_language_handler
export -f verify_signature
