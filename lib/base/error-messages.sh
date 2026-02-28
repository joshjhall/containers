#!/bin/bash
# Standardized error messages for consistent user experience
#
# This script provides centralized error messages that can be used across
# all feature scripts for consistent error reporting and easier maintenance.
#
# Usage:
#   source /tmp/build-scripts/base/error-messages.sh
#
#   error_package_not_found "libssl-dev"
#   error_checksum_mismatch "python" "$expected" "$actual"
#   error_download_failed "https://example.com/file.tar.gz" "404"

# Prevent multiple sourcing
if [ -n "${_ERROR_MESSAGES_LOADED:-}" ]; then
    return 0
fi
_ERROR_MESSAGES_LOADED=1

set -euo pipefail

# Source logging if available
if [ -f "/tmp/build-scripts/base/logging.sh" ]; then
    # shellcheck source=lib/base/logging.sh
    source "/tmp/build-scripts/base/logging.sh"
elif [ -f "$(dirname "${BASH_SOURCE[0]}")/logging.sh" ]; then
    # shellcheck source=lib/base/logging.sh
    source "$(dirname "${BASH_SOURCE[0]}")/logging.sh"
fi

# ============================================================================
# Package and Dependency Errors
# ============================================================================

# Error: Package not found in repositories
error_package_not_found() {
    local package="${1:-unknown}"
    log_error "Package '$package' not found in repositories"
    log_error "Try: apt-cache search $package"
    log_error "Or check if the package name has changed in this Debian version"
}

# Error: Dependency installation failed
error_dependency_failed() {
    local package="${1:-unknown}"
    local reason="${2:-unknown reason}"
    log_error "Failed to install dependency: $package"
    log_error "Reason: $reason"
    log_error "Try: apt-get update && apt-get install -y $package"
}

# Error: Required command not found
error_command_not_found() {
    local command="${1:-unknown}"
    local install_hint="${2:-}"
    log_error "Required command '$command' not found"
    if [ -n "$install_hint" ]; then
        log_error "Install with: $install_hint"
    fi
}

# ============================================================================
# Download and Network Errors
# ============================================================================

# Error: Download failed
error_download_failed() {
    local url="${1:-unknown}"
    local http_code="${2:-}"
    log_error "Failed to download: $url"
    if [ -n "$http_code" ]; then
        log_error "HTTP status code: $http_code"
    fi
    log_error "Check network connectivity and URL validity"
}

# Error: Connection timeout
error_connection_timeout() {
    local url="${1:-unknown}"
    local timeout="${2:-30}"
    log_error "Connection timed out after ${timeout}s: $url"
    log_error "Check network connectivity or increase timeout"
}

# Error: SSL/TLS certificate error
error_certificate_error() {
    local url="${1:-unknown}"
    log_error "SSL/TLS certificate verification failed: $url"
    log_error "This may indicate a MITM attack or misconfigured certificate"
    log_error "Do NOT bypass certificate verification unless you understand the risks"
}

# ============================================================================
# Verification and Security Errors
# ============================================================================

# Error: Checksum mismatch
error_checksum_mismatch() {
    local file="${1:-unknown}"
    local expected="${2:-unknown}"
    local actual="${3:-unknown}"
    log_error "Checksum verification failed for: $file"
    log_error "Expected: $expected"
    log_error "Got:      $actual"
    log_error "The downloaded file may be corrupted or tampered with"
}

# Error: GPG signature verification failed
error_gpg_verification_failed() {
    local file="${1:-unknown}"
    local key_id="${2:-}"
    log_error "GPG signature verification failed for: $file"
    if [ -n "$key_id" ]; then
        log_error "Expected signing key: $key_id"
    fi
    log_error "The file may be tampered with or signed with wrong key"
}

# Error: GPG key not found
error_gpg_key_not_found() {
    local key_id="${1:-unknown}"
    local keyserver="${2:-keyserver.ubuntu.com}"
    log_error "GPG key not found: $key_id"
    log_error "Try: gpg --keyserver $keyserver --recv-keys $key_id"
}

# Error: Sigstore verification failed
error_sigstore_verification_failed() {
    local file="${1:-unknown}"
    log_error "Sigstore signature verification failed for: $file"
    log_error "Check if the signature and certificate files exist and are valid"
}

# ============================================================================
# Version and Compatibility Errors
# ============================================================================

# Error: Version not found
error_version_not_found() {
    local tool="${1:-unknown}"
    local version="${2:-unknown}"
    log_error "Version $version of $tool not found"
    log_error "Check available versions or use 'latest' if supported"
}

# Error: Unsupported version
error_unsupported_version() {
    local tool="${1:-unknown}"
    local version="${2:-unknown}"
    local min_version="${3:-}"
    log_error "Version $version of $tool is not supported"
    if [ -n "$min_version" ]; then
        log_error "Minimum required version: $min_version"
    fi
}

# Error: Architecture not supported
error_architecture_not_supported() {
    local tool="${1:-unknown}"
    local arch="${2:-$(uname -m)}"
    log_error "$tool does not support architecture: $arch"
    log_error "Supported architectures may include: x86_64, aarch64, armv7l"
}

# Error: OS not supported
error_os_not_supported() {
    local tool="${1:-unknown}"
    local os="${2:-$(uname -s)}"
    log_error "$tool does not support OS: $os"
}

# ============================================================================
# File System Errors
# ============================================================================

# Error: File not found
error_file_not_found() {
    local file="${1:-unknown}"
    log_error "File not found: $file"
    log_error "Check the file path and permissions"
}

# Error: Directory not found
error_directory_not_found() {
    local dir="${1:-unknown}"
    log_error "Directory not found: $dir"
    log_error "Create with: mkdir -p $dir"
}

# Error: Permission denied
error_permission_denied() {
    local path="${1:-unknown}"
    local operation="${2:-access}"
    log_error "Permission denied: cannot $operation $path"
    log_error "Check file permissions or run with appropriate privileges"
}

# Error: Disk space insufficient
error_disk_space() {
    local path="${1:-/}"
    local required="${2:-unknown}"
    log_error "Insufficient disk space at: $path"
    if [ "$required" != "unknown" ]; then
        log_error "Required space: $required"
    fi
    log_error "Free up disk space and try again"
}

# ============================================================================
# Configuration Errors
# ============================================================================

# Error: Invalid configuration
error_invalid_config() {
    local config="${1:-unknown}"
    local reason="${2:-invalid value}"
    log_error "Invalid configuration: $config"
    log_error "Reason: $reason"
}

# Error: Missing required environment variable
error_missing_env_var() {
    local var="${1:-unknown}"
    local description="${2:-}"
    log_error "Required environment variable not set: $var"
    if [ -n "$description" ]; then
        log_error "Description: $description"
    fi
    log_error "Set with: export $var=value"
}

# Error: Invalid environment variable value
error_invalid_env_var() {
    local var="${1:-unknown}"
    local value="${2:-}"
    local expected="${3:-}"
    log_error "Invalid value for environment variable: $var"
    if [ -n "$value" ]; then
        log_error "Got: $value"
    fi
    if [ -n "$expected" ]; then
        log_error "Expected: $expected"
    fi
}

# ============================================================================
# Build and Installation Errors
# ============================================================================

# Error: Build failed
error_build_failed() {
    local component="${1:-unknown}"
    local log_file="${2:-}"
    log_error "Build failed for: $component"
    if [ -n "$log_file" ] && [ -f "$log_file" ]; then
        log_error "Check build log: $log_file"
        log_error "Last 10 lines of log:"
        command tail -10 "$log_file" | while read -r line; do
            log_error "  $line"
        done
    fi
}

# Error: Installation failed
error_installation_failed() {
    local component="${1:-unknown}"
    local reason="${2:-unknown reason}"
    log_error "Installation failed for: $component"
    log_error "Reason: $reason"
}

# Error: Post-install verification failed
error_verification_failed() {
    local component="${1:-unknown}"
    local test_cmd="${2:-}"
    log_error "Post-installation verification failed for: $component"
    if [ -n "$test_cmd" ]; then
        log_error "Verification command: $test_cmd"
    fi
    log_error "The installation may be incomplete or corrupted"
}

# ============================================================================
# Export Functions
# ============================================================================

export -f error_package_not_found
export -f error_dependency_failed
export -f error_command_not_found
export -f error_download_failed
export -f error_connection_timeout
export -f error_certificate_error
export -f error_checksum_mismatch
export -f error_gpg_verification_failed
export -f error_gpg_key_not_found
export -f error_sigstore_verification_failed
export -f error_version_not_found
export -f error_unsupported_version
export -f error_architecture_not_supported
export -f error_os_not_supported
export -f error_file_not_found
export -f error_directory_not_found
export -f error_permission_denied
export -f error_disk_space
export -f error_invalid_config
export -f error_missing_env_var
export -f error_invalid_env_var
export -f error_build_failed
export -f error_installation_failed
export -f error_verification_failed
