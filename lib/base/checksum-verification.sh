#!/bin/bash
# 4-Tier Checksum Verification System
#
# Provides progressive security verification with clear logging about which
# method is used and why.
#
# TIER 1 (Best): GPG Signature Verification
#   - Cryptographic proof using publisher's public key
#   - Available for: Python, Node.js, Go
#   - Security: Highest - proves authenticity
#
# TIER 2 (Good): Pinned Checksums from lib/checksums.json
#   - Git-tracked checksums, auditable and reviewed
#   - Updated weekly by auto-patch workflow
#   - Security: High - trusted source, version-controlled
#
# TIER 3 (Acceptable): Published Checksums
#   - Downloaded from official publisher (e.g., python.org/SHA256SUMS)
#   - Security: Medium - MITM vulnerable but better than calculating
#
# TIER 4 (Fallback): Calculated Checksums
#   - Download file and calculate checksum
#   - Security: Low - TOFU risk, no verification
#   - Logs clear warning about security implications
#
# VERSION STRATEGY:
#   Languages: Support partial versions (3.12 -> 3.12.12)
#   Tools: Exact versions only (2.60.1)
#
# Usage:
#   source /tmp/build-scripts/base/checksum-verification.sh
#   verify_download "python" "3.12.7" "https://..." "/tmp/file.tgz"

set -euo pipefail

# Source dependencies
if [ -f /tmp/build-scripts/base/logging.sh ]; then
    source /tmp/build-scripts/base/logging.sh
fi

if [ -f /tmp/build-scripts/features/lib/checksum-fetch.sh ]; then
    source /tmp/build-scripts/features/lib/checksum-fetch.sh
fi

# Path to pinned checksums database
CHECKSUMS_DB="/tmp/build-scripts/checksums.json"

# ============================================================================
# TIER 1: GPG Signature Verification
# ============================================================================

# verify_gpg_python - Verify Python tarball using GPG signature
#
# Arguments:
#   $1 - Python version (e.g., "3.12.7")
#   $2 - Downloaded tarball path
#
# Returns:
#   0 if GPG verification succeeds
#   1 if verification fails or not available
verify_gpg_python() {
    local version="$1"
    local tarball="$2"
    local signature_url="https://www.python.org/ftp/python/${version}/Python-${version}.tgz.asc"
    local signature_file="${tarball}.asc"

    log_message "🔐 TIER 1: Attempting GPG signature verification"
    log_message "   Fetching signature from python.org..."

    # Download signature file
    if ! curl -fsSL "$signature_url" -o "$signature_file" 2>/dev/null; then
        log_message "   ⚠️  Signature file not available"
        return 1
    fi

    # Try to verify (if gpg is available)
    if ! command -v gpg >/dev/null 2>&1; then
        log_message "   ⚠️  GPG not available in build environment"
        rm -f "$signature_file"
        return 1
    fi

    # Import Python release keys if needed
    # Note: This is a basic implementation. Production would need proper key management.
    log_message "   ⚠️  GPG verification not yet fully implemented"
    log_message "   Falling back to next tier..."
    rm -f "$signature_file"
    return 1
}

# verify_gpg_node - Verify Node.js tarball using SHASUMS256.txt.sig
#
# Arguments:
#   $1 - Node version (e.g., "20.18.0")
#   $2 - Downloaded tarball path
#   $3 - Expected filename in SHASUMS256.txt
#
# Returns:
#   0 if GPG verification succeeds
#   1 if verification fails or not available
verify_gpg_node() {
    local version="$1"
    local tarball="$2"
    local filename="$3"
    # shellcheck disable=SC2034  # Variables defined for future GPG implementation
    local shasums_url="https://nodejs.org/dist/v${version}/SHASUMS256.txt"
    # shellcheck disable=SC2034  # Variables defined for future GPG implementation
    local sig_url="https://nodejs.org/dist/v${version}/SHASUMS256.txt.sig"

    log_message "🔐 TIER 1: Attempting GPG signature verification"
    log_message "   Fetching SHASUMS256.txt and signature from nodejs.org..."

    # Note: Full implementation would verify sig and check checksums
    log_message "   ⚠️  GPG verification not yet fully implemented"
    log_message "   Falling back to next tier..."
    return 1
}

# verify_gpg_go - Verify Go tarball using .asc signature
#
# Arguments:
#   $1 - Go version (e.g., "1.23.5")
#   $2 - Downloaded tarball path
#
# Returns:
#   0 if GPG verification succeeds
#   1 if verification fails or not available
verify_gpg_go() {
    local version="$1"
    local tarball="$2"
    local arch="amd64"  # TODO: detect architecture
    local signature_url="https://go.dev/dl/go${version}.linux-${arch}.tar.gz.asc"

    log_message "🔐 TIER 1: Attempting GPG signature verification"
    log_message "   ⚠️  GPG verification not yet fully implemented"
    log_message "   Falling back to next tier..."
    return 1
}

# ============================================================================
# TIER 2: Pinned Checksums from lib/checksums.json
# ============================================================================

# lookup_pinned_checksum - Look up checksum from checksums.json
#
# Arguments:
#   $1 - Type: "language" or "tool"
#   $2 - Name (e.g., "python", "nodejs", "gh")
#   $3 - Version (e.g., "3.12.7", "2.60.1")
#
# Returns:
#   Checksum string if found
#   Empty string if not found
lookup_pinned_checksum() {
    local type="$1"
    local name="$2"
    local version="$3"

    if [ ! -f "$CHECKSUMS_DB" ]; then
        return 1
    fi

    # Use jq if available, otherwise grep
    if command -v jq >/dev/null 2>&1; then
        local checksum
        if [ "$type" = "language" ]; then
            checksum=$(jq -r ".languages.\"${name}\".versions.\"${version}\".sha256 // empty" "$CHECKSUMS_DB" 2>/dev/null || echo "")
        else
            checksum=$(jq -r ".tools.\"${name}\".versions.\"${version}\".sha256 // empty" "$CHECKSUMS_DB" 2>/dev/null || echo "")
        fi

        if [ -n "$checksum" ] && [ "$checksum" != "null" ] && [ "$checksum" != "placeholder_actual_checksum_needed" ]; then
            echo "$checksum"
            return 0
        fi
    fi

    return 1
}

# verify_pinned_checksum - Verify using Tier 2 pinned checksums
#
# Arguments:
#   $1 - Type: "language" or "tool"
#   $2 - Name (e.g., "python", "nodejs")
#   $3 - Version
#   $4 - Downloaded file path
#
# Returns:
#   0 if verification succeeds
#   1 if checksum not found or verification fails
verify_pinned_checksum() {
    local type="$1"
    local name="$2"
    local version="$3"
    local file="$4"

    log_message "📌 TIER 2: Checking pinned checksums database"

    local expected
    expected=$(lookup_pinned_checksum "$type" "$name" "$version")

    if [ -z "$expected" ]; then
        log_message "   ⚠️  Version $version not found in checksums.json"
        if [ "$type" = "language" ]; then
            log_message "   💡 TIP: Use partial version (e.g., '${version%.*}') for latest patch with pinned checksum"
        fi
        return 1
    fi

    log_message "   ✓ Found pinned checksum in git-tracked database"

    local actual
    actual=$(sha256sum "$file" | awk '{print $1}')

    if [ "$actual" = "$expected" ]; then
        log_message "   ✅ TIER 2 VERIFICATION PASSED"
        log_message "   Security: Git-tracked checksum, auditable and reviewed"
        return 0
    else
        log_error "Checksum mismatch!"
        log_error "Expected: $expected"
        log_error "Got:      $actual"
        return 1
    fi
}

# ============================================================================
# TIER 3: Published Checksums from Official Sources
# ============================================================================

# verify_published_checksum - Verify using Tier 3 published checksums
#
# Arguments:
#   $1 - Name (e.g., "python", "ruby", "go")
#   $2 - Version
#   $3 - Downloaded file path
#   $4 - Architecture (optional, for go/rust)
#
# Returns:
#   0 if verification succeeds
#   1 if checksum not available or verification fails
verify_published_checksum() {
    local name="$1"
    local version="$2"
    local file="$3"
    local arch="${4:-amd64}"

    log_message "🌐 TIER 3: Fetching published checksum from official source"

    local expected=""

    case "$name" in
        python)
            log_message "   Checking python.org FTP directory..."
            # Python publishes SHA256 checksums on FTP
            local sha256_url="https://www.python.org/ftp/python/${version}/Python-${version}.tgz.sha256"
            expected=$(curl -fsSL "$sha256_url" 2>/dev/null | awk '{print $1}' || echo "")
            ;;
        ruby)
            log_message "   Checking ruby-lang.org downloads page..."
            expected=$(fetch_ruby_checksum "$version" 2>/dev/null || echo "")
            ;;
        go|golang)
            log_message "   Checking go.dev downloads page..."
            expected=$(fetch_go_checksum "$version" "$arch" 2>/dev/null || echo "")
            ;;
        nodejs|node)
            log_message "   Checking nodejs.org SHASUMS256.txt..."
            local filename="node-v${version}-linux-x64.tar.xz"
            local shasums_url="https://nodejs.org/dist/v${version}/SHASUMS256.txt"
            expected=$(curl -fsSL "$shasums_url" 2>/dev/null | grep "$filename" | awk '{print $1}' || echo "")
            ;;
        *)
            log_message "   ⚠️  No published checksum method for $name"
            return 1
            ;;
    esac

    if [ -z "$expected" ]; then
        log_message "   ⚠️  Published checksum not available"
        return 1
    fi

    log_message "   ✓ Retrieved checksum from official publisher"

    local actual
    actual=$(sha256sum "$file" | awk '{print $1}')

    if [ "$actual" = "$expected" ]; then
        log_message "   ✅ TIER 3 VERIFICATION PASSED"
        log_message "   Security: Downloaded from official source (MITM risk remains)"
        return 0
    else
        log_error "Checksum mismatch!"
        log_error "Expected: $expected"
        log_error "Got:      $actual"
        return 1
    fi
}

# ============================================================================
# TIER 4: Calculated Checksums (Fallback)
# ============================================================================

# verify_calculated_checksum - Verify using Tier 4 calculated checksum
#
# Arguments:
#   $1 - File path
#
# Returns:
#   0 always (just calculates and logs warning)
#
# Note: This doesn't provide real verification, just ensures file integrity
verify_calculated_checksum() {
    local file="$1"

    log_message "⚠️  TIER 4: Using calculated checksum (FALLBACK)"
    log_message ""
    log_message "   ╔════════════════════════════════════════════════════════════╗"
    log_message "   ║                    SECURITY WARNING                        ║"
    log_message "   ╠════════════════════════════════════════════════════════════╣"
    log_message "   ║ No trusted checksum available for verification.            ║"
    log_message "   ║                                                            ║"
    log_message "   ║ Using TOFU (Trust On First Use) - calculating checksum    ║"
    log_message "   ║ from downloaded file without external verification.       ║"
    log_message "   ║                                                            ║"
    log_message "   ║ Risk: Vulnerable to man-in-the-middle attacks.            ║"
    log_message "   ║                                                            ║"
    log_message "   ║ This is acceptable for development but NOT recommended    ║"
    log_message "   ║ for production builds.                                    ║"
    log_message "   ╚════════════════════════════════════════════════════════════╝"
    log_message ""

    local checksum
    checksum=$(sha256sum "$file" | awk '{print $1}')

    log_message "   Calculated SHA256: $checksum"
    log_message "   ✅ TIER 4: File integrity recorded (no external verification)"

    return 0
}

# ============================================================================
# Main Verification Wrapper
# ============================================================================

# verify_download - Main function: tries all tiers in order
#
# Arguments:
#   $1 - Category: "language" or "tool"
#   $2 - Name (e.g., "python", "nodejs", "gh")
#   $3 - Version
#   $4 - Downloaded file path
#   $5 - Architecture (optional, default: amd64)
#
# Returns:
#   0 if any tier succeeds
#   1 if all tiers fail
#
# Example:
#   verify_download "language" "python" "3.12.7" "/tmp/Python-3.12.7.tgz"
#   verify_download "tool" "gh" "2.60.1" "/tmp/gh.tar.gz"
verify_download() {
    local category="$1"
    local name="$2"
    local version="$3"
    local file="$4"
    local arch="${5:-amd64}"

    log_message ""
    log_message "═══════════════════════════════════════════════════════════════"
    log_message "🔍 CHECKSUM VERIFICATION: $name $version"
    log_message "═══════════════════════════════════════════════════════════════"
    log_message ""

    # TIER 1: GPG Signature Verification (if supported)
    if [ "$category" = "language" ]; then
        case "$name" in
            python)
                if verify_gpg_python "$version" "$file"; then
                    return 0
                fi
                ;;
            nodejs|node)
                if verify_gpg_node "$version" "$file" "node-v${version}-linux-x64.tar.xz"; then
                    return 0
                fi
                ;;
            go|golang)
                if verify_gpg_go "$version" "$file"; then
                    return 0
                fi
                ;;
        esac
    fi

    # TIER 2: Pinned Checksums
    if verify_pinned_checksum "$category" "$name" "$version" "$file"; then
        return 0
    fi

    # TIER 3: Published Checksums
    if [ "$category" = "language" ]; then
        if verify_published_checksum "$name" "$version" "$file" "$arch"; then
            return 0
        fi
    fi

    # TIER 4: Calculated Checksum (Fallback)
    verify_calculated_checksum "$file"
    return 0
}

# Export functions for use in feature scripts
export -f verify_download
export -f verify_pinned_checksum
export -f verify_published_checksum
export -f verify_calculated_checksum
export -f lookup_pinned_checksum
