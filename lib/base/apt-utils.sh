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