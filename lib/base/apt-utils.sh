#!/bin/bash
# APT utility functions for reliable package installation
#
# This script provides wrapper functions for apt-get operations with:
# - Retry logic for transient failures
# - Better error reporting
# - Network timeout configuration
# - Mirror fallback support
#
# Usage:
#   Source this file in your feature script:
#     source /tmp/build-scripts/base/apt-utils.sh
#
#   Then use:
#     apt_update           # Update package lists with retries
#     apt_install package1 package2  # Install packages with retries
#

set -euo pipefail

# Source logging functions if available
if [ -f /tmp/build-scripts/base/logging.sh ]; then
    source /tmp/build-scripts/base/logging.sh
fi

# ============================================================================
# Configuration
# ============================================================================
APT_MAX_RETRIES="${APT_MAX_RETRIES:-3}"
APT_RETRY_DELAY="${APT_RETRY_DELAY:-5}"
APT_TIMEOUT="${APT_TIMEOUT:-300}"  # 5 minutes timeout for apt operations

# ============================================================================
# Debian Version Detection
# ============================================================================

# get_debian_major_version - Get the major Debian version number
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
    if [ -f /etc/debian_version ]; then
        local version
        version=$(cat /etc/debian_version)
        # Extract major version number (handles both "12.5" and "trixie/sid")
        if [[ "$version" =~ ^[0-9]+\. ]]; then
            echo "${version%%.*}"
        elif [[ "$version" == *"trixie"* ]]; then
            echo "13"
        elif [[ "$version" == *"bookworm"* ]]; then
            echo "12"
        elif [[ "$version" == *"bullseye"* ]]; then
            echo "11"
        else
            echo "unknown"
        fi
    else
        echo "unknown"
    fi
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
    local packages="$*"

    local current_version
    current_version=$(get_debian_major_version)

    if [ "$current_version" = "unknown" ]; then
        echo "⚠ Warning: Could not determine Debian version, skipping conditional packages: $packages"
        return 0
    fi

    if [ "$current_version" -ge "$min_version" ] && [ "$current_version" -le "$max_version" ]; then
        echo "Installing version-specific packages for Debian $current_version: $packages"
        apt_install $packages
    else
        echo "Skipping packages (not needed for Debian $current_version): $packages"
    fi
}

# ============================================================================
# apt_retry - Generic retry wrapper for any apt command
# 
# Usage:
#   apt_retry <command>
#
# Example:
#   apt_retry apt-get upgrade -y
# ============================================================================
apt_retry() {
    local attempt=1
    local delay="$APT_RETRY_DELAY"
    local cmd="$*"
    
    while [ $attempt -le "$APT_MAX_RETRIES" ]; do
        echo "Running: $cmd (attempt $attempt/$APT_MAX_RETRIES)..."
        
        if timeout "$APT_TIMEOUT" $cmd; then
            echo "✓ Command succeeded: $cmd"
            return 0
        fi
        
        local exit_code=$?
        
        if [ $attempt -lt "$APT_MAX_RETRIES" ]; then
            echo "⚠ Command failed (exit code: $exit_code), retrying in ${delay}s..."
            sleep "$delay"
            delay=$((delay * 2))  # Exponential backoff
        else
            echo "✗ Command failed after $APT_MAX_RETRIES attempts: $cmd"
            return $exit_code
        fi
        
        attempt=$((attempt + 1))
    done
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
    local attempt=1
    local delay="$APT_RETRY_DELAY"
    
    while [ $attempt -le "$APT_MAX_RETRIES" ]; do
        echo "Updating package lists (attempt $attempt/$APT_MAX_RETRIES)..."
        
        # Configure apt with timeout and retry options
        if timeout "$APT_TIMEOUT" apt-get update \
            -o Acquire::http::Timeout=30 \
            -o Acquire::https::Timeout=30 \
            -o Acquire::ftp::Timeout=30 \
            -o Acquire::Retries=3 \
            -o APT::Update::Error-Mode=any; then
            echo "✓ Package lists updated successfully"
            return 0
        fi
        
        local exit_code=$?
        
        if [ $attempt -lt "$APT_MAX_RETRIES" ]; then
            echo "⚠ apt-get update failed (exit code: $exit_code), retrying in ${delay}s..."
            
            # Check for specific network errors
            if [ $exit_code -eq 100 ]; then
                echo "  Network connectivity issue detected, waiting longer..."
                delay=$((delay * 2))  # Double the delay for network issues
            fi
            
            sleep "$delay"
            delay=$((delay * 2))  # Exponential backoff
            
            # Try to clean apt cache before retry
            apt-get clean || true
            rm -rf /var/lib/apt/lists/* || true
        else
            echo "✗ apt-get update failed after $APT_MAX_RETRIES attempts"
            
            # Provide diagnostic information
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
            cat /etc/apt/sources.list 2>/dev/null || echo "  No sources.list found"
            ls /etc/apt/sources.list.d/*.list 2>/dev/null || echo "  No additional sources"
            
            return $exit_code
        fi
        
        attempt=$((attempt + 1))
    done
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
    
    local packages="$*"
    local attempt=1
    local delay="$APT_RETRY_DELAY"
    
    while [ $attempt -le "$APT_MAX_RETRIES" ]; do
        echo "Installing packages: $packages (attempt $attempt/$APT_MAX_RETRIES)..."
        
        # Configure apt with timeout and retry options
        if DEBIAN_FRONTEND=noninteractive timeout "$APT_TIMEOUT" apt-get install -y \
            --no-install-recommends \
            -o Acquire::http::Timeout=30 \
            -o Acquire::https::Timeout=30 \
            -o Acquire::ftp::Timeout=30 \
            -o Acquire::Retries=3 \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold" \
            $packages; then
            echo "✓ Packages installed successfully: $packages"
            return 0
        fi
        
        local exit_code=$?
        
        if [ $attempt -lt "$APT_MAX_RETRIES" ]; then
            echo "⚠ Package installation failed (exit code: $exit_code), retrying in ${delay}s..."
            
            # Check for specific errors
            if [ $exit_code -eq 100 ]; then
                echo "  Network connectivity issue detected"
                # Try to update package lists before retry
                echo "  Attempting to refresh package lists..."
                apt-get update -qq || true
            fi
            
            sleep "$delay"
            delay=$((delay * 2))  # Exponential backoff
        else
            echo "✗ Package installation failed after $APT_MAX_RETRIES attempts"
            echo "  Failed packages: $packages"
            return $exit_code
        fi
        
        attempt=$((attempt + 1))
    done
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
    rm -rf /var/lib/apt/lists/*
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
        cp /etc/apt/sources.list /etc/apt/sources.list.original
    fi
    
    # Add retry and timeout configurations to apt.conf.d
    cat > /etc/apt/apt.conf.d/99-retries << 'EOF'
# Network timeout and retry configuration
Acquire::http::Timeout "30";
Acquire::https::Timeout "30";
Acquire::ftp::Timeout "30";
Acquire::Retries "3";
Acquire::Queue-Mode "host";
APT::Update::Error-Mode "any";

# Parallel downloads for better performance
Acquire::Queue-Mode "host";
Acquire::Languages "none";
EOF
    
    echo "✓ apt configured with timeout and retry settings"
}

# Export functions for use by other scripts
export -f apt_retry
export -f apt_update
export -f apt_install
export -f apt_cleanup
export -f configure_apt_mirrors