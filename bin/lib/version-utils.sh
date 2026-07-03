#!/bin/bash
# Version utility functions
#
# Description:
#   Shared version validation and comparison logic.
#   Used by check-versions.sh and update-versions.sh.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/version-utils.sh"
#   if validate_version "1.2.3"; then
#       echo "Valid version"
#   fi

# Header guard to prevent multiple sourcing
if [ -n "${_BIN_LIB_VERSION_UTILS_SH_INCLUDED:-}" ]; then
    return 0
fi
readonly _BIN_LIB_VERSION_UTILS_SH_INCLUDED=1

set -euo pipefail

# ============================================================================
# Version Validation
# ============================================================================

# validate_version - Validate version format
#
# Arguments:
#   $1 - Version string to validate
#
# Returns:
#   0 if valid version format, 1 if invalid
#
# Description:
#   Checks for invalid values and basic version format.
#   Used by update-versions.sh to validate before updating.
validate_version() {
    local version="$1"

    # Check for invalid values
    if [ -z "$version" ] || [ "$version" = "null" ] || [ "$version" = "undefined" ] || [ "$version" = "error" ]; then
        return 1
    fi

    # Check for basic version format (should contain numbers)
    if ! echo "$version" | command grep -qE '[0-9]'; then
        return 1
    fi

    # Check for common version patterns
    if echo "$version" | command grep -qE '^[0-9]+(\.([0-9]+|[xX]))*([+-].*)?$|^[0-9]{4}-[0-9]{2}-[0-9]{2}'; then
        return 0
    fi

    # For some specific version formats that don't match the above
    # but are still valid (like some Java versions)
    if echo "$version" | command grep -qE '^[0-9]+[._][0-9]+'; then
        return 0
    fi

    return 1
}

# validate_sha256 - Validate SHA256 checksum format
#
# Arguments:
#   $1 - Checksum string to validate
#
# Returns:
#   0 if valid SHA256 format, 1 if invalid
#
# Description:
#   SHA256 checksums are exactly 64 hexadecimal characters.
validate_sha256() {
    local checksum="$1"

    # SHA256 is exactly 64 hexadecimal characters
    if [[ "$checksum" =~ ^[a-fA-F0-9]{64}$ ]]; then
        return 0
    else
        return 1
    fi
}

# validate_sha512 - Validate SHA512 checksum format
#
# Arguments:
#   $1 - Checksum string to validate
#
# Returns:
#   0 if valid SHA512 format, 1 if invalid
#
# Description:
#   SHA512 checksums are exactly 128 hexadecimal characters.
validate_sha512() {
    local checksum="$1"

    # SHA512 is exactly 128 hexadecimal characters
    if [[ "$checksum" =~ ^[a-fA-F0-9]{128}$ ]]; then
        return 0
    else
        return 1
    fi
}

# extract_action_version - Normalize a GitHub Actions `uses:` git ref to a
# comparable version string.
#
# Arguments:
#   $1 - The ref after the `@` in a `uses:` line, e.g. any of:
#          "ed142fd0673e97e23eac54620cfb913e5ce36c25 # v0.36.0"  (SHA-pinned)
#          "v0.36.0"                                              (tag)
#          "0.36.0"                                               (bare tag)
#          "master"                                               (branch)
#
# Outputs:
#   The normalized version (leading `v` stripped), e.g. "0.36.0". For a
#   branch ref with no version comment (e.g. "master") the ref is echoed
#   through unchanged so the caller can skip it.
#
# Description:
#   Third-party actions are SHA-pinned (see docs/security/action-pinning.md)
#   with the human-readable version carried in a trailing `# <version>`
#   comment. The version therefore lives in the comment, NOT in the `@`-ref.
#   Naively taking the text after `@` (as an early version of check-versions
#   did) captures the 40-hex SHA and mangles the comparison, so the tool
#   reports the action as perpetually outdated. Read the comment when the
#   ref is a SHA; fall back to the ref itself for plain tags.
extract_action_version() {
    local ref="$1"

    # SHA-pinned: the version is in the trailing `# <version>` comment.
    if [[ "$ref" =~ ^[0-9a-f]{40}([[:space:]]|$) ]]; then
        printf '%s\n' "$ref" |
            command sed -n 's/.*#[[:space:]]*v\{0,1\}\([0-9][^[:space:]]*\).*/\1/p'
        return 0
    fi

    # Plain tag (`v0.36.0` / `0.36.0`) or branch (`master`): strip any comment
    # and an optional leading `v`.
    printf '%s' "$ref" |
        command sed -e 's/[[:space:]]*#.*$//' -e 's/^v//' -e 's/[[:space:]]//g'
}

# ============================================================================
# Version Comparison
# ============================================================================

# version_matches - Check if current version matches latest
#
# Arguments:
#   $1 - Current version (may be partial, e.g., "22" or "3.12")
#   $2 - Latest version (full version, e.g., "22.18.0" or "3.12.8")
#
# Returns:
#   0 if versions match (exact or partial), 1 if different
#
# Description:
#   Used by check-versions.sh to determine if version is up-to-date.
#   Supports partial version matching (e.g., "22" matches "22.18.0").
version_matches() {
    local current="$1"
    local latest="$2"

    # Handle exact matches first
    if [[ "$current" == "$latest" ]]; then
        return 0
    fi

    # Handle prefix matching with proper version boundaries
    # e.g., "22" matches "22.18.0" but not "220.0.0"
    if [[ "$latest" == "$current."* ]] || [[ "$latest" == "$current" ]]; then
        return 0
    fi

    return 1
}

# ============================================================================
# Version Bumping
# ============================================================================

# bump_version - Increment a semantic version
#
# Arguments:
#   $1 - Current version (X.Y.Z format)
#   $2 - Bump type: major, minor, or patch
#
# Output:
#   Prints the new version to stdout
#
# Description:
#   Used by release.sh to calculate the next version number.
bump_version() {
    local current_version="$1"
    local bump_type="$2"

    IFS='.' read -r major minor patch <<<"$current_version"

    case "$bump_type" in
        major)
            major=$((major + 1))
            minor=0
            patch=0
            ;;
        minor)
            minor=$((minor + 1))
            patch=0
            ;;
        patch)
            patch=$((patch + 1))
            ;;
        *)
            echo -e "${RED:-}Error: Invalid bump type${NC:-}" >&2
            return 1
            ;;
    esac

    echo "${major}.${minor}.${patch}"
}
