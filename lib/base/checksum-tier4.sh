#!/bin/bash
# Tier 4 TOFU (Trust On First Use) Checksum Verification
#
# Extracted from checksum-verification.sh for modularity.
# Provides the Tier 4 fallback (calculated checksum with no external
# verification) and the build-end TOFU summary printer.
#
# Usage:
#   source /tmp/build-scripts/base/checksum-tier4.sh
#   verify_calculated_checksum "/tmp/file.tgz"
#   print_tofu_summary

# Prevent multiple sourcing
if [ -n "${_CHECKSUM_TIER4_LOADED:-}" ]; then
    return 0
fi
_CHECKSUM_TIER4_LOADED=1

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

# ============================================================================
# TIER 4: Calculated Checksums (Fallback)
# ============================================================================

# verify_calculated_checksum - Verify using Tier 4 calculated checksum
#
# Arguments:
#   $1 - File path
#
# Returns:
#   2 always (unverified/TOFU - no external verification available)
#
# Note: This doesn't provide real verification, just ensures file integrity.
#       Returns 2 (not 0) so callers can distinguish "verified" (0) from
#       "verification failed" (1) from "no verification available" (2).
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
    checksum=$(sha256sum "$file" | command awk '{print $1}')

    log_message "   Calculated SHA256: $checksum"
    log_message "   ⚠️  TIER 4: File integrity recorded (no external verification)"

    return 2
}

# ============================================================================
# TOFU Build Summary
# ============================================================================

# print_tofu_summary - Print aggregate summary of TOFU downloads at end of build
#
# Checks the TOFU log file and prints a warning box if any Tier 4 downloads occurred.
# Call this at the end of the build to give users visibility into TOFU events.
#
# Returns:
#   0 always (informational only)
print_tofu_summary() {
    local tofu_log="${BUILD_LOG_DIR:-/tmp/container-build}/tofu-downloads.log"

    if [ ! -f "$tofu_log" ] || [ ! -s "$tofu_log" ]; then
        return 0
    fi

    local count
    count=$(/usr/bin/wc -l <"$tofu_log")

    log_message ""
    log_message "╔════════════════════════════════════════════════════════════════╗"
    log_message "║              TOFU DOWNLOAD SUMMARY ($count download(s))              ║"
    log_message "╠════════════════════════════════════════════════════════════════╣"
    log_message "║ The following downloads used Tier 4 TOFU (Trust On First Use) ║"
    log_message "║ and were NOT cryptographically verified:                      ║"
    log_message "║                                                              ║"
    while IFS= read -r line; do
        /usr/bin/printf "║   - %-56s ║\n" "$line" >&2 2>/dev/null || log_message "║   - $line"
    done <"$tofu_log"
    log_message "║                                                              ║"
    log_message "║ For production builds, set:                                  ║"
    log_message "║   --build-arg REQUIRE_VERIFIED_DOWNLOADS=true                ║"
    log_message "║   --build-arg PRODUCTION_MODE=true                           ║"
    log_message "║                                                              ║"
    log_message "║ To fix: add pinned checksums to lib/checksums.json           ║"
    log_message "╚════════════════════════════════════════════════════════════════╝"
    log_message ""

    return 0
}

# Export functions for use in feature scripts
protected_export verify_calculated_checksum print_tofu_summary
