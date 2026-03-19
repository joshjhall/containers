#!/bin/bash
# GitHub Release Binary Installer
#
# Description:
#   Provides a reusable function to install pre-built binaries from GitHub
#   (or GitLab) releases. Handles architecture detection, checksum fetching,
#   download verification via the 4-tier system, and post-processing (dpkg,
#   tar extract, gunzip, or direct binary install).
#
# Usage:
#   source /tmp/build-scripts/features/lib/install-github-release.sh
#   install_github_release "tool" "$VERSION" "$BASE_URL" \
#       "file_amd64" "file_arm64" "checksums_txt" "dpkg"
#
# Requirements:
#   - feature-header.sh must be sourced (for log_message, create_secure_temp_dir)
#   - download-verify.sh must be sourced (for download_and_verify, download_and_extract)
#   - checksum-fetch.sh must be sourced (for fetch_github_checksums_txt, etc.)
#   - checksum-verification.sh must be sourced (for verify_download, register_tool_checksum_fetcher)

set -euo pipefail

# Per-tool fetcher data arrays (used by _github_release_checksum_fetcher)
declare -gA _TOOL_FETCHER_TYPES      # tool_name -> checksums_txt|sha256|sha512
declare -gA _TOOL_FETCHER_URLS       # tool_name -> URL to fetch checksum from
declare -gA _TOOL_FETCHER_FILENAMES  # tool_name -> filename to match in checksums.txt

# Defensive check: ensure required dependencies are available
if ! declare -f log_message >/dev/null 2>&1; then
    echo "ERROR: install-github-release.sh requires feature-header.sh to be sourced first" >&2
    return 1
fi

# Source checksum verification system for 4-tier verify_download
if [ -f /tmp/build-scripts/base/checksum-verification.sh ]; then
    source /tmp/build-scripts/base/checksum-verification.sh
fi

# ============================================================================
# Generic Checksum Fetcher (replaces per-tool eval'd closures)
# ============================================================================

# _github_release_checksum_fetcher - Dispatch fetcher using per-tool data arrays
#
# Arguments:
#   $1 - version (unused, passed by verify_tool_published_checksum)
#   $2 - arch (unused, passed by verify_tool_published_checksum)
#   $3 - tool_name (used to look up URL/filename in global arrays)
#
_github_release_checksum_fetcher() {
    local tool_name="$3"
    local _type="${_TOOL_FETCHER_TYPES[$tool_name]:-}"
    case "$_type" in
        checksums_txt)
            fetch_github_checksums_txt "${_TOOL_FETCHER_URLS[$tool_name]}" \
                "${_TOOL_FETCHER_FILENAMES[$tool_name]}" 2>/dev/null
            ;;
        sha256)
            fetch_github_sha256_file "${_TOOL_FETCHER_URLS[$tool_name]}" 2>/dev/null
            ;;
        sha512)
            fetch_github_sha512_file "${_TOOL_FETCHER_URLS[$tool_name]}" 2>/dev/null
            ;;
    esac
}
export -f _github_release_checksum_fetcher

# ============================================================================
# Main Installation Function
# ============================================================================

# install_github_release - Download, verify, and install a release binary
#
# Arguments:
#   $1 - tool_name:     Human-readable name (for log messages)
#   $2 - version:       Version string (for logging)
#   $3 - base_url:      URL prefix up to the filename
#   $4 - amd64_file:    Filename for amd64 architecture
#   $5 - arm64_file:    Filename for arm64 architecture
#   $6 - checksum_type: One of: checksums_txt, sha256, sha512, calculate
#   $7 - install_type:  One of: binary, extract:<binary_name>, dpkg, gunzip
#
# Checksum types:
#   checksums_txt - Fetch from checksums.txt alongside release
#   sha256        - Fetch from individual .sha256 file
#   sha512        - Fetch from individual .sha512 file
#   calculate     - Download and calculate SHA256 (no published checksums)
#
# Install types:
#   binary              - Direct binary: mv to /usr/local/bin, chmod +x
#   extract:<name>      - Tar extract, find <name> binary, mv to /usr/local/bin
#   extract_flat:<name> - Tar extract specific file directly to /usr/local/bin
#   dpkg                - Install .deb package via dpkg -i
#   gunzip              - Decompress .gz, mv to /usr/local/bin, chmod +x
#
# Returns:
#   0 on success
#   1 on failure (unsupported arch, checksum fetch failure, download failure)
#
# Example:
#   install_github_release "duf" "$DUF_VERSION" \
#       "https://github.com/muesli/duf/releases/download/v${DUF_VERSION}" \
#       "duf_${DUF_VERSION}_linux_amd64.deb" \
#       "duf_${DUF_VERSION}_linux_arm64.deb" \
#       "checksums_txt" "dpkg"
#
install_github_release() {
    local tool_name="$1"
    local version="$2"
    local base_url="$3"
    local amd64_file="$4"
    local arm64_file="$5"
    local checksum_type="$6"
    local install_type="$7"

    log_message "Installing ${tool_name} ${version}..."

    # Architecture detection
    local arch
    arch=$(dpkg --print-architecture)
    local filename
    case "$arch" in
        amd64) filename="$amd64_file" ;;
        arm64) filename="$arm64_file" ;;
        *)
            log_warning "${tool_name} not available for architecture ${arch}, skipping..."
            return 1
            ;;
    esac

    local file_url="${base_url}/${filename}"

    # Register a Tier 3 fetcher based on checksum_type.
    # The fetcher captures the URL/filename context from this call.
    case "$checksum_type" in
        checksums_txt)
            _TOOL_FETCHER_TYPES["$tool_name"]="checksums_txt"
            _TOOL_FETCHER_URLS["$tool_name"]="${base_url}/checksums.txt"
            _TOOL_FETCHER_FILENAMES["$tool_name"]="$filename"
            register_tool_checksum_fetcher "$tool_name" "_github_release_checksum_fetcher"
            ;;
        sha256)
            _TOOL_FETCHER_TYPES["$tool_name"]="sha256"
            _TOOL_FETCHER_URLS["$tool_name"]="${file_url}.sha256"
            register_tool_checksum_fetcher "$tool_name" "_github_release_checksum_fetcher"
            ;;
        sha512)
            _TOOL_FETCHER_TYPES["$tool_name"]="sha512"
            _TOOL_FETCHER_URLS["$tool_name"]="${file_url}.sha512"
            register_tool_checksum_fetcher "$tool_name" "_github_release_checksum_fetcher"
            ;;
        calculate)
            # No published checksums — don't register fetcher, will fall through to Tier 4
            ;;
        *)
            log_error "Unknown checksum type: ${checksum_type}"
            return 1
            ;;
    esac

    # Download file to temp location
    local build_temp
    build_temp=$(create_secure_temp_dir)
    cd "$build_temp"

    local local_file="${tool_name}-download"
    log_message "Downloading ${tool_name} for ${arch}..."
    if ! command curl -L -f --retry 3 --retry-delay 2 --retry-all-errors --progress-bar -o "$local_file" "$file_url"; then
        log_error "Download failed for ${tool_name} ${version}"
        cd /
        return 1
    fi

    # Run 4-tier verification
    local verify_rc=0
    verify_download "tool" "$tool_name" "$version" "$local_file" "$arch" || verify_rc=$?

    if [ "$verify_rc" -eq 1 ]; then
        log_error "Verification failed for ${tool_name} ${version}"
        cd /
        return 1
    fi
    # verify_rc=0 (verified) or verify_rc=2 (TOFU, allowed by policy) — proceed

    # For extract_flat, extract from the already-downloaded file
    if [[ "$install_type" == extract_flat:* ]]; then
        local binary_name="${install_type#extract_flat:}"
        log_command "Extracting ${tool_name}" \
            tar -xzf "$local_file" -C "/usr/local/bin" "$binary_name"
        cd /
        log_message "✓ ${tool_name} ${version} installed successfully"
        return 0
    fi

    # Post-processing based on install type
    case "$install_type" in
        binary)
            log_command "Installing ${tool_name} binary" \
                command mv "$local_file" "/usr/local/bin/${tool_name}"
            log_command "Setting ${tool_name} permissions" \
                chmod +x "/usr/local/bin/${tool_name}"
            ;;
        extract:*)
            local binary_name="${install_type#extract:}"
            log_command "Extracting ${tool_name}" \
                tar -xzf "$local_file"
            # Find the binary (may be in a subdirectory)
            local found_binary
            found_binary=$(command find . -name "$binary_name" -type f | command head -1)
            if [ -z "$found_binary" ]; then
                log_error "Binary '${binary_name}' not found after extracting ${tool_name}"
                cd /
                return 1
            fi
            log_command "Installing ${tool_name} binary" \
                command mv "$found_binary" "/usr/local/bin/${binary_name}"
            log_command "Setting ${tool_name} permissions" \
                chmod +x "/usr/local/bin/${binary_name}"
            ;;
        dpkg)
            log_command "Installing ${tool_name} package" \
                dpkg -i "$local_file"
            ;;
        gunzip)
            log_command "Extracting ${tool_name}" \
                gunzip "$local_file"
            # After gunzip, the file loses the extension — find the decompressed file
            local decompressed
            decompressed=$(command find . -maxdepth 1 -type f ! -name "*.gz" | command head -1)
            if [ -z "$decompressed" ]; then
                log_error "Decompressed file not found for ${tool_name}"
                cd /
                return 1
            fi
            log_command "Installing ${tool_name} binary" \
                command mv "$decompressed" "/usr/local/bin/${tool_name}"
            log_command "Setting ${tool_name} permissions" \
                chmod +x "/usr/local/bin/${tool_name}"
            ;;
        *)
            log_error "Unknown install type: ${install_type}"
            cd /
            return 1
            ;;
    esac

    cd /
    log_message "✓ ${tool_name} ${version} installed successfully"
    return 0
}

# Export function for use in other scripts
export -f install_github_release
