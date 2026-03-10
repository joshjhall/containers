#!/bin/bash
# Cosign Installation Helper
#
# Shared cosign (Sigstore) installation logic used by both docker.sh and
# kubernetes.sh features. Installs cosign for container image signing and
# verification.
#
# Dependencies (must be sourced before this file):
#   - feature-header.sh (log_message, log_error, log_command, map_arch,
#     create_secure_temp_dir, log_feature_end)
#   - checksum-fetch.sh (fetch_github_checksums_txt)
#   - checksum-verification.sh (register_tool_checksum_fetcher, verify_download)
#
# Usage:
#   source /tmp/build-scripts/base/cosign-install.sh
#   install_cosign

# Prevent multiple sourcing
if [ -n "${_COSIGN_INSTALL_LOADED:-}" ]; then
    return 0
fi
_COSIGN_INSTALL_LOADED=1

# Source export utilities
# shellcheck source=lib/shared/export-utils.sh
if [ -f "/tmp/build-scripts/shared/export-utils.sh" ]; then
    source "/tmp/build-scripts/shared/export-utils.sh"
elif [ -f "$(dirname "${BASH_SOURCE[0]}")/../shared/export-utils.sh" ]; then
    source "$(dirname "${BASH_SOURCE[0]}")/../shared/export-utils.sh"
fi

# ============================================================================
# Cosign Installation
# ============================================================================

# install_cosign - Install cosign (Sigstore) for container image verification
#
# Skips installation if cosign is already present. Downloads the .deb package,
# runs 4-tier checksum verification, and installs via dpkg.
#
# Requires: feature-header.sh, checksum-fetch.sh, checksum-verification.sh
#   to be sourced by the calling feature script.
install_cosign() {
    if command -v cosign &> /dev/null; then
        log_message "cosign already installed, skipping..."
        return 0
    fi

    log_message "Installing cosign (container image signing and verification)..."

    # Set cosign version
    local cosign_version="3.0.2"

    # Detect architecture for cosign
    local cosign_arch
    cosign_arch=$(map_arch "amd64" "arm64")

    # Construct the cosign package filename
    local cosign_package="cosign_${cosign_version}_${cosign_arch}.deb"
    local cosign_url="https://github.com/sigstore/cosign/releases/download/v${cosign_version}/${cosign_package}"

    # Register Tier 3 fetcher for cosign (if not already registered)
    if [ -z "${_TOOL_CHECKSUM_FETCHERS[cosign]+x}" ]; then
        _fetch_cosign_checksum() {
            local _ver="$1"
            local _arch="$2"
            local _pkg="cosign_${_ver}_${_arch}.deb"
            local _url="https://github.com/sigstore/cosign/releases/download/v${_ver}/cosign_checksums.txt"
            fetch_github_checksums_txt "$_url" "$_pkg" 2>/dev/null
        }
        register_tool_checksum_fetcher "cosign" "_fetch_cosign_checksum"
    fi

    # Download cosign
    local build_temp
    build_temp=$(create_secure_temp_dir)
    cd "$build_temp" || return 1
    log_message "Downloading cosign..."
    if ! command curl -L -f --retry 3 --retry-delay 2 --retry-all-errors --progress-bar -o "cosign.deb" "$cosign_url"; then
        log_error "Failed to download cosign ${cosign_version}"
        cd /
        command rm -rf "$build_temp"
        return 1
    fi

    # Run 4-tier verification
    local verify_rc=0
    verify_download "tool" "cosign" "$cosign_version" "cosign.deb" "$cosign_arch" || verify_rc=$?
    if [ "$verify_rc" -eq 1 ]; then
        log_error "Verification failed for cosign ${cosign_version}"
        cd /
        command rm -rf "$build_temp"
        return 1
    fi

    log_message "✓ cosign v${cosign_version} verified successfully"

    # Install the verified package
    log_command "Installing cosign package" \
        dpkg -i cosign.deb

    cd /
    log_command "Cleaning up build directory" \
        command rm -rf "$build_temp"
}

# Export function for use in other scripts
protected_export install_cosign
