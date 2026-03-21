#!/bin/bash
# Tier 2 Pinned Checksum Verification
#
# Extracted from checksum-verification.sh for modularity.
# Provides lookup and verification of git-tracked pinned checksums
# from lib/checksums.json.
#
# Usage:
#   source /tmp/build-scripts/base/checksum-pinned.sh
#   checksum=$(lookup_pinned_checksum "language" "python" "3.12.7")
#   verify_pinned_checksum "language" "python" "3.12.7" "/tmp/file.tgz"

# Prevent multiple sourcing
if [ -n "${_CHECKSUM_PINNED_LOADED:-}" ]; then
    return 0
fi
_CHECKSUM_PINNED_LOADED=1

set -euo pipefail

# Source export utilities
# shellcheck source=lib/shared/export-utils.sh
if [ -f "/tmp/build-scripts/shared/export-utils.sh" ]; then
    source "/tmp/build-scripts/shared/export-utils.sh"
elif [ -f "$(dirname "${BASH_SOURCE[0]}")/../shared/export-utils.sh" ]; then
    source "$(dirname "${BASH_SOURCE[0]}")/../shared/export-utils.sh"
fi

# Source dependencies
if [ -f /tmp/build-scripts/base/logging.sh ]; then
    source /tmp/build-scripts/base/logging.sh
fi

# Path to pinned checksums database
CHECKSUMS_DB="/tmp/build-scripts/checksums.json"

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
    local arch="${4:-}"

    if [ ! -f "$CHECKSUMS_DB" ]; then
        return 1
    fi

    # Use jq if available, otherwise grep
    if command -v jq >/dev/null 2>&1; then
        local checksum=""
        if [ "$type" = "language" ]; then
            checksum=$(jq -r ".languages.\"${name}\".versions.\"${version}\".sha256 // empty" "$CHECKSUMS_DB" 2>/dev/null || echo "")
        else
            # For tools, try arch-specific lookup first, then arch-independent
            if [ -n "$arch" ]; then
                checksum=$(jq -r ".tools.\"${name}\".versions.\"${version}\".checksums.\"${arch}\".sha256 // empty" "$CHECKSUMS_DB" 2>/dev/null || echo "")
            fi
            if [ -z "$checksum" ] || [ "$checksum" = "null" ]; then
                checksum=$(jq -r ".tools.\"${name}\".versions.\"${version}\".sha256 // empty" "$CHECKSUMS_DB" 2>/dev/null || echo "")
            fi
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
#   $5 - Architecture (optional, e.g., "amd64", "arm64")
#
# Returns:
#   0 if verification succeeds
#   1 if checksum not found or verification fails
verify_pinned_checksum() {
    local type="$1"
    local name="$2"
    local version="$3"
    local file="$4"
    local arch="${5:-}"

    log_message "📌 TIER 2: Checking pinned checksums database"

    local expected
    expected=$(lookup_pinned_checksum "$type" "$name" "$version" "$arch")

    if [ -z "$expected" ]; then
        log_message "   ⚠️  Version $version not found in checksums.json"
        if [ "$type" = "language" ]; then
            log_message "   💡 TIP: Use partial version (e.g., '${version%.*}') for latest patch with pinned checksum"
        fi
        return 1
    fi

    log_message "   ✓ Found pinned checksum in git-tracked database"

    local actual
    actual=$(sha256sum "$file" | command awk '{print $1}')

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

# Export functions for use in feature scripts
protected_export lookup_pinned_checksum verify_pinned_checksum
