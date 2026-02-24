#!/bin/bash
# GitHub Release Binary Installer
#
# Description:
#   Provides a reusable function to install pre-built binaries from GitHub
#   (or GitLab) releases. Handles architecture detection, checksum fetching,
#   download verification, and post-processing (dpkg, tar extract, gunzip,
#   or direct binary install).
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

set -euo pipefail

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
#   $6 - checksum_type: One of: checksums_txt, sha512, calculate
#   $7 - install_type:  One of: binary, extract:<binary_name>, dpkg, gunzip
#
# Checksum types:
#   checksums_txt - Fetch from checksums.txt alongside release
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

    # Fetch or calculate checksum
    local checksum=""
    case "$checksum_type" in
        checksums_txt)
            log_message "Fetching ${tool_name} checksum..."
            local checksums_url="${base_url}/checksums.txt"
            if ! checksum=$(fetch_github_checksums_txt "$checksums_url" "$filename" 2>/dev/null); then
                log_error "Failed to fetch checksum for ${tool_name} ${version}"
                return 1
            fi
            ;;
        sha512)
            log_message "Fetching ${tool_name} SHA512 checksum..."
            local sha512_url="${file_url}.sha512"
            if ! checksum=$(fetch_github_sha512_file "$sha512_url" 2>/dev/null); then
                log_error "Failed to fetch SHA512 checksum for ${tool_name} ${version}"
                return 1
            fi
            if ! validate_checksum_format "$checksum" "sha512"; then
                log_error "Invalid SHA512 checksum format for ${tool_name} ${version}"
                return 1
            fi
            ;;
        calculate)
            log_message "Calculating checksum for ${tool_name} ${version}..."
            if ! checksum=$(calculate_checksum_sha256 "$file_url" 2>/dev/null); then
                log_error "Failed to calculate checksum for ${tool_name} ${version}"
                return 1
            fi
            ;;
        *)
            log_error "Unknown checksum type: ${checksum_type}"
            return 1
            ;;
    esac

    # For extract_flat, use download_and_extract directly (no temp dir needed)
    if [[ "$install_type" == extract_flat:* ]]; then
        local binary_name="${install_type#extract_flat:}"
        log_message "Downloading and verifying ${tool_name} for ${arch}..."
        download_and_extract \
            "$file_url" \
            "$checksum" \
            "/usr/local/bin" \
            "$binary_name"
        log_message "✓ ${tool_name} ${version} installed successfully"
        return 0
    fi

    # Download to temp directory
    local build_temp
    build_temp=$(create_secure_temp_dir)
    cd "$build_temp"

    local local_file="${tool_name}-download"
    log_message "Downloading and verifying ${tool_name} for ${arch}..."
    if ! download_and_verify "$file_url" "$checksum" "$local_file"; then
        cd /
        return 1
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
            found_binary=$(find . -name "$binary_name" -type f | head -1)
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
            decompressed=$(find . -maxdepth 1 -type f ! -name "*.gz" | head -1)
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
