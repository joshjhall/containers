#!/bin/bash
# Debian version detection utilities
#
# Provides functions for detecting and comparing Debian version numbers.
# Uses multiple fallback methods for robustness (os-release, debian_version,
# lsb_release).
#
# Usage:
#   Source this file in your script:
#     source /tmp/build-scripts/base/debian-version.sh
#
#   Then use:
#     DEBIAN_VERSION=$(get_debian_major_version)
#     if is_debian_version 13; then
#         # Trixie-specific code
#     fi
#
# Include guard: _DEBIAN_VERSION_LOADED

# Prevent multiple sourcing
if [ -n "${_DEBIAN_VERSION_LOADED:-}" ]; then
    return 0
fi
_DEBIAN_VERSION_LOADED=1

# Source export utilities
# shellcheck source=lib/shared/export-utils.sh
if [ -f "/tmp/build-scripts/shared/export-utils.sh" ]; then
    source "/tmp/build-scripts/shared/export-utils.sh"
elif [ -f "$(dirname "${BASH_SOURCE[0]}")/../shared/export-utils.sh" ]; then
    source "$(dirname "${BASH_SOURCE[0]}")/../shared/export-utils.sh"
fi

# ============================================================================
# Debian Version Detection
# ============================================================================

# get_debian_major_version - Get the major Debian version number
#
# Uses multiple fallback methods for robustness:
#   1. /etc/os-release (preferred - standard)
#   2. /etc/debian_version (fallback)
#   3. lsb_release command (if available)
#
# Returns:
#   The major version number (e.g., "11", "12", "13")
#   Returns "unknown" if version cannot be determined
#
# Example:
#   DEBIAN_VERSION=$(get_debian_major_version)
#   if [ "$DEBIAN_VERSION" = "13" ]; then
#       # Trixie-specific code
#   fi
get_debian_major_version() {
    local version=""

    # Method 1: Try /etc/os-release (most reliable)
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        source /etc/os-release 2>/dev/null || true
        if [ -n "${VERSION_ID:-}" ]; then
            # Extract major version (handles "12", "12.5", etc.)
            version="${VERSION_ID%%.*}"
            echo "$version"
            return 0
        elif [ -n "${VERSION_CODENAME:-}" ]; then
            # Map codename to version
            case "$VERSION_CODENAME" in
                trixie)
                    echo "13"
                    return 0
                    ;;
                bookworm)
                    echo "12"
                    return 0
                    ;;
                bullseye)
                    echo "11"
                    return 0
                    ;;
            esac
        fi
    fi

    # Method 2: Try /etc/debian_version (fallback)
    if [ -f /etc/debian_version ]; then
        version=$(command cat /etc/debian_version 2>/dev/null || echo "")
        if [ -n "$version" ]; then
            # Extract major version number (handles both "12.5" and "trixie/sid")
            if [[ "$version" =~ ^[0-9]+\. ]]; then
                echo "${version%%.*}"
                return 0
            elif [[ "$version" =~ ^[0-9]+$ ]]; then
                echo "$version"
                return 0
            elif [[ "$version" == *"trixie"* ]] || [[ "$version" == *"sid"* ]]; then
                echo "13"
                return 0
            elif [[ "$version" == *"bookworm"* ]]; then
                echo "12"
                return 0
            elif [[ "$version" == *"bullseye"* ]]; then
                echo "11"
                return 0
            fi
        fi
    fi

    # Method 3: Try lsb_release (if available)
    if command -v lsb_release >/dev/null 2>&1; then
        version=$(lsb_release -sr 2>/dev/null | command cut -d. -f1 || echo "")
        if [[ "$version" =~ ^[0-9]+$ ]]; then
            echo "$version"
            return 0
        fi
        # Try codename if numeric version not available
        local codename
        codename=$(lsb_release -sc 2>/dev/null || echo "")
        case "$codename" in
            trixie)
                echo "13"
                return 0
                ;;
            bookworm)
                echo "12"
                return 0
                ;;
            bullseye)
                echo "11"
                return 0
                ;;
        esac
    fi

    # All methods failed
    echo "unknown"
    return 1
}

# is_debian_version - Check if running specific Debian version or newer
#
# Usage:
#   is_debian_version <min_version>
#
# Returns:
#   0 if current version >= min_version
#   1 otherwise
#
# Example:
#   if is_debian_version 13; then
#       echo "Running Debian 13 or newer"
#   fi
is_debian_version() {
    local min_version="$1"
    local current_version
    current_version=$(get_debian_major_version)

    if [ "$current_version" = "unknown" ]; then
        return 1
    fi

    if [ "$current_version" -ge "$min_version" ]; then
        return 0
    else
        return 1
    fi
}

# Export functions for use by other scripts
protected_export get_debian_major_version is_debian_version
