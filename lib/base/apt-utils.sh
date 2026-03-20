#!/bin/bash
# APT utility functions for reliable package installation
#
# This script provides wrapper functions for apt-get operations with:
# - Retry logic for transient failures
# - Better error reporting
# - Network timeout configuration
# - Mirror fallback support
#
# Sub-modules (sourced automatically):
# - debian-version.sh: Debian version detection (get_debian_major_version, is_debian_version)
# - apt-repository.sh: GPG key and repository management (add_apt_repository_key)
#
# Usage:
#   Source this file in your feature script:
#     source /tmp/build-scripts/base/apt-utils.sh
#
#   Then use:
#     apt_update           # Update package lists with retries
#     apt_install package1 package2  # Install packages with retries
#

# Prevent multiple sourcing
if [ -n "${_APT_UTILS_LOADED:-}" ]; then
    return 0
fi
_APT_UTILS_LOADED=1

set -euo pipefail

# Source export utilities
# shellcheck source=lib/shared/export-utils.sh
if [ -f "/tmp/build-scripts/shared/export-utils.sh" ]; then
    source "/tmp/build-scripts/shared/export-utils.sh"
elif [ -f "$(dirname "${BASH_SOURCE[0]}")/../shared/export-utils.sh" ]; then
    source "$(dirname "${BASH_SOURCE[0]}")/../shared/export-utils.sh"
fi

# Source logging functions if available
if [ -f /tmp/build-scripts/base/logging.sh ]; then
    source /tmp/build-scripts/base/logging.sh
fi

# Debian version detection (get_debian_major_version, is_debian_version)
# shellcheck source=lib/base/debian-version.sh
if [ -f "/tmp/build-scripts/base/debian-version.sh" ]; then
    source "/tmp/build-scripts/base/debian-version.sh"
elif [ -f "$(dirname "${BASH_SOURCE[0]}")/debian-version.sh" ]; then
    source "$(dirname "${BASH_SOURCE[0]}")/debian-version.sh"
fi

# GPG key and repository management (add_apt_repository_key)
# shellcheck source=lib/base/apt-repository.sh
if [ -f "/tmp/build-scripts/base/apt-repository.sh" ]; then
    source "/tmp/build-scripts/base/apt-repository.sh"
elif [ -f "$(dirname "${BASH_SOURCE[0]}")/apt-repository.sh" ]; then
    source "$(dirname "${BASH_SOURCE[0]}")/apt-repository.sh"
fi

# ============================================================================
# Configuration
# ============================================================================
APT_MAX_RETRIES="${APT_MAX_RETRIES:-3}"
APT_RETRY_DELAY="${APT_RETRY_DELAY:-5}"
APT_TIMEOUT="${APT_TIMEOUT:-300}"  # 5 minutes timeout for apt operations
APT_ACQUIRE_TIMEOUT="${APT_ACQUIRE_TIMEOUT:-30}"  # Per-request acquire timeout
APT_NETWORK_ERROR_CODE=100        # apt exit code for network/repository errors

# apt_install_conditional - Install packages based on Debian version
#
# Usage:
#   apt_install_conditional <min_version> <package1> [package2...]
#
# Example:
#   # Install lzma packages only on Debian 11/12, not on 13+
#   apt_install_conditional 11 12 lzma lzma-dev
#
#   # Install new package only on Debian 13+
#   apt_install_conditional 13 99 new-package
apt_install_conditional() {
    local min_version="$1"
    local max_version="$2"
    shift 2
    local packages=("$@")

    local current_version
    current_version=$(get_debian_major_version)

    if [ "$current_version" = "unknown" ]; then
        echo "⚠ Warning: Could not determine Debian version, skipping conditional packages: ${packages[*]}"
        return 0
    fi

    if [ "$current_version" -ge "$min_version" ] && [ "$current_version" -le "$max_version" ]; then
        echo "Installing version-specific packages for Debian $current_version: ${packages[*]}"
        apt_install "${packages[@]}"
    else
        echo "Skipping packages (not needed for Debian $current_version): ${packages[*]}"
    fi
}

# ============================================================================
# apt_retry - Generic retry wrapper for any apt command
#
# Usage:
#   apt_retry [--retry-hook <func>] [--failure-hook <func>] [--] <command...>
#
# Options:
#   --retry-hook <func>   Function called between retries with exit code arg
#   --failure-hook <func> Function called after all retries exhausted with exit code arg
#   --                    Separates options from the command
#
# Example:
#   apt_retry apt-get upgrade -y
#   apt_retry --retry-hook my_cleanup --failure-hook my_diagnose -- apt-get update
# ============================================================================
apt_retry() {
    local retry_hook=""
    local failure_hook=""

    # Parse optional flags
    while [ $# -gt 0 ]; do
        case "$1" in
            --retry-hook)
                retry_hook="$2"
                shift 2
                ;;
            --failure-hook)
                failure_hook="$2"
                shift 2
                ;;
            --)
                shift
                break
                ;;
            *)
                break
                ;;
        esac
    done

    local attempt=1
    local delay="$APT_RETRY_DELAY"
    local cmd_array=("$@")

    while [ $attempt -le "$APT_MAX_RETRIES" ]; do
        echo "Running: ${cmd_array[*]} (attempt $attempt/$APT_MAX_RETRIES)..."

        # Use || to capture the exit code without triggering set -e
        local exit_code=0
        timeout "$APT_TIMEOUT" "${cmd_array[@]}" || exit_code=$?

        if [ $exit_code -eq 0 ]; then
            echo "✓ Command succeeded: ${cmd_array[*]}"
            return 0
        fi

        if [ $attempt -lt "$APT_MAX_RETRIES" ]; then
            echo "⚠ Command failed (exit code: $exit_code), retrying in ${delay}s..."

            # Call retry hook if provided
            if [ -n "$retry_hook" ]; then
                "$retry_hook" "$exit_code" || true
            fi

            sleep "$delay"
            delay=$((delay * 2))  # Exponential backoff
        else
            echo "✗ Command failed after $APT_MAX_RETRIES attempts: ${cmd_array[*]}"

            # Call failure hook if provided
            if [ -n "$failure_hook" ]; then
                "$failure_hook" "$exit_code" || true
            fi

            return $exit_code
        fi

        attempt=$((attempt + 1))
    done
}

# ============================================================================
# _apt_diagnose_network_failure - Print diagnostic info after apt update failure
#
# Checks DNS resolution, connectivity to common repositories, and lists
# configured apt sources. Called from apt_update() on final failure.
# ============================================================================
_apt_diagnose_network_failure() {
    echo ""
    echo "=== Diagnostic Information ==="
    echo "Network connectivity test:"
    # Test DNS
    if ! timeout 5 nslookup debian.org >/dev/null 2>&1; then
        echo "  ✗ DNS resolution failed"
    else
        echo "  ✓ DNS resolution working"
    fi

    # Test connectivity to common package repositories
    for host in deb.debian.org security.debian.org archive.ubuntu.com; do
        if timeout 5 ping -c 1 "$host" >/dev/null 2>&1; then
            echo "  ✓ Can reach $host"
        else
            echo "  ✗ Cannot reach $host"
        fi
    done

    echo ""
    echo "Current apt sources:"
    command cat /etc/apt/sources.list 2>/dev/null || echo "  No sources.list found"
    command ls /etc/apt/sources.list.d/*.list 2>/dev/null || echo "  No additional sources"
}

# ============================================================================
# _apt_update_on_retry - Hook called between apt_update retries
#
# Logs network errors and cleans apt cache before retry.
#
# Arguments:
#   $1 - exit code from the failed attempt
# ============================================================================
_apt_update_on_retry() {
    local exit_code="$1"

    if [ "$exit_code" -eq "$APT_NETWORK_ERROR_CODE" ]; then
        echo "  Network connectivity issue detected"
    fi

    # Clean apt cache before retry
    apt-get clean || true
    command rm -rf /var/lib/apt/lists/* || true
}

# ============================================================================
# apt_update - Update package lists with retry logic
#
# Usage:
#   apt_update
#
# Environment Variables:
#   APT_MAX_RETRIES - Maximum retry attempts (default: 3)
#   APT_RETRY_DELAY - Initial delay between retries in seconds (default: 5)
# ============================================================================
apt_update() {
    apt_retry \
        --retry-hook _apt_update_on_retry \
        --failure-hook _apt_diagnose_network_failure \
        -- \
        apt-get update \
            -o Acquire::http::Timeout=${APT_ACQUIRE_TIMEOUT} \
            -o Acquire::https::Timeout=${APT_ACQUIRE_TIMEOUT} \
            -o Acquire::ftp::Timeout=${APT_ACQUIRE_TIMEOUT} \
            -o Acquire::Retries=3 \
            -o APT::Update::Error-Mode=any
}

# ============================================================================
# _fix_dpkg_state - Fix half-configured packages from a failed apt install
#
# Runs dpkg --configure -a, then identifies and purges packages stuck in a
# broken state. Does NOT run apt-get --fix-broken install: it can pull packages
# from alternative sources (e.g. Debian when CRAN was intended), creating a
# mixed-source state with unresolvable dependencies.
# ============================================================================
_fix_dpkg_state() {
    dpkg --configure -a 2>/dev/null || true
    # || true makes pipeline set -e/pipefail safe when grep finds no matches.
    _broken_pkgs=$(dpkg --audit 2>/dev/null | command grep -oP '^\S+' || true)
    if [ -n "$_broken_pkgs" ]; then
        echo "  Removing half-installed packages..."
        # Single dpkg call with --force-depends handles circular deps atomically
        # shellcheck disable=SC2086
        dpkg --purge --force-depends --force-remove-reinstreq $_broken_pkgs 2>/dev/null || true
        dpkg --configure -a 2>/dev/null || true
    fi
}

# ============================================================================
# _clean_apt_cache - Clean cached archives so stale/mismatched files are re-fetched
# ============================================================================
_clean_apt_cache() {
    apt-get clean || true
    command rm -rf /var/cache/apt/archives/partial/* || true
}

# ============================================================================
# _apt_install_on_retry - Hook called between apt_install retries
#
# Logs network errors, recovers dpkg state, cleans apt cache, and refreshes
# package lists on network failure.
#
# Arguments:
#   $1 - exit code from the failed attempt
# ============================================================================
_apt_install_on_retry() {
    local exit_code="$1"

    if [ "$exit_code" -eq "$APT_NETWORK_ERROR_CODE" ]; then
        echo "  Network connectivity issue detected"
        echo "  Recovering dpkg and apt state before retry..."
        _fix_dpkg_state
        _clean_apt_cache
        # Refresh package lists to pick up any mirror sync changes
        apt-get update -qq || true
    fi
}

# ============================================================================
# apt_install - Install packages with retry logic
#
# Arguments:
#   $@ - Package names to install
#
# Usage:
#   apt_install build-essential git curl
#
# Environment Variables:
#   APT_MAX_RETRIES - Maximum retry attempts (default: 3)
#   APT_RETRY_DELAY - Initial delay between retries in seconds (default: 5)
# ============================================================================
apt_install() {
    if [ $# -eq 0 ]; then
        echo "Error: apt_install requires at least one package name"
        return 1
    fi

    # Validate package names before installation (security: prevent command injection)
    local pkg
    for pkg in "$@"; do
        # Package names can contain: letters, numbers, dots, hyphens, plus, tilde, colon
        # Version specifications: equals, greater/less than, wildcards
        # See: https://www.debian.org/doc/debian-policy/ch-controlfields.html#s-f-source
        # Examples: package, package=1.0, package>=1.0, package=1.0-*
        if [[ ! "$pkg" =~ ^[a-zA-Z0-9.+~:=\<\>*-]+$ ]]; then
            echo "Error: Invalid package name '$pkg'"
            echo "  Package names must contain only: a-z A-Z 0-9 . + ~ : = < > * -"
            return 1
        fi
    done

    DEBIAN_FRONTEND=noninteractive apt_retry \
        --retry-hook _apt_install_on_retry \
        -- \
        apt-get install -y --no-install-recommends --fix-missing \
            -o Acquire::http::Timeout=${APT_ACQUIRE_TIMEOUT} \
            -o Acquire::https::Timeout=${APT_ACQUIRE_TIMEOUT} \
            -o Acquire::ftp::Timeout=${APT_ACQUIRE_TIMEOUT} \
            -o Acquire::Retries=3 \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold" \
            "$@"
}

# ============================================================================
# apt_cleanup - Clean up apt cache to save space
#
# Usage:
#   apt_cleanup
# ============================================================================
apt_cleanup() {
    echo "Cleaning up apt cache..."
    apt-get clean
    command rm -rf /var/lib/apt/lists/*
    echo "✓ apt cache cleaned"
}

# ============================================================================
# configure_apt_mirrors - Configure apt to use faster/more reliable mirrors
#
# Usage:
#   configure_apt_mirrors
#
# Note: This is optional and can be called before apt_update if needed
# ============================================================================
configure_apt_mirrors() {
    echo "Configuring apt mirrors for better reliability..."

    # Create a backup of the original sources.list
    if [ -f /etc/apt/sources.list ] && [ ! -f /etc/apt/sources.list.original ]; then
        command cp /etc/apt/sources.list /etc/apt/sources.list.original
    fi

    # Add retry and timeout configurations to apt.conf.d
    command cat > /etc/apt/apt.conf.d/99-retries << EOF
# Network timeout and retry configuration
Acquire::http::Timeout "${APT_ACQUIRE_TIMEOUT}";
Acquire::https::Timeout "${APT_ACQUIRE_TIMEOUT}";
Acquire::ftp::Timeout "${APT_ACQUIRE_TIMEOUT}";
Acquire::Retries "3";
Acquire::Queue-Mode "host";
APT::Update::Error-Mode "any";

# Parallel downloads for better performance
Acquire::Languages "none";
EOF

    echo "✓ apt configured with timeout and retry settings"
}

# Export functions for use by other scripts
protected_export _apt_diagnose_network_failure _apt_update_on_retry
protected_export _fix_dpkg_state _clean_apt_cache _apt_install_on_retry
protected_export apt_retry apt_update apt_install apt_cleanup
protected_export configure_apt_mirrors apt_install_conditional
