#!/bin/bash
# Terraform companion tool installations: Terragrunt, terraform-docs, tflint, Trivy
#
# Expected variables from parent script:
#   TERRAGRUNT_VERSION, TFDOCS_VERSION, TFLINT_VERSION
#
# Expected sourced utilities:
#   checksum-fetch.sh, download-verify.sh, retry-utils.sh, checksum-verification.sh
#   apt-utils.sh (for Trivy APT installation)
#
# Source this file from terraform.sh after Terraform is installed.

# Source 4-tier checksum verification if not already loaded
if [ -z "${_CHECKSUM_VERIFICATION_LOADED:-}" ]; then
    source /tmp/build-scripts/base/checksum-verification.sh
fi

# ============================================================================
# Terragrunt Installation
# ============================================================================
install_terragrunt() {
    log_message "Installing Terragrunt ${TERRAGRUNT_VERSION}..."
    local ARCH
    ARCH=$(map_arch_or_skip "amd64" "arm64")

    if [ -n "$ARCH" ]; then
        local TERRAGRUNT_BINARY="terragrunt_linux_${ARCH}"
        local TERRAGRUNT_URL="https://github.com/gruntwork-io/terragrunt/releases/download/v${TERRAGRUNT_VERSION}/${TERRAGRUNT_BINARY}"

        # Register Tier 3 fetcher for terragrunt
        _fetch_terragrunt_checksum() {
            local _ver="$1"
            local _arch="$2"
            local _bin="terragrunt_linux_${_arch}"
            local _url="https://github.com/gruntwork-io/terragrunt/releases/download/v${_ver}/SHA256SUMS"
            fetch_github_checksums_txt "$_url" "$_bin" 2>/dev/null
        }
        register_tool_checksum_fetcher "terragrunt" "_fetch_terragrunt_checksum"

        # Download Terragrunt
        local BUILD_TEMP
        BUILD_TEMP=$(create_secure_temp_dir)
        cd "$BUILD_TEMP" || return 1
        log_message "Downloading Terragrunt..."
        if ! command curl -L -f --retry 3 --retry-delay 2 --retry-all-errors --progress-bar -o "terragrunt" "$TERRAGRUNT_URL"; then
            log_error "Failed to download Terragrunt ${TERRAGRUNT_VERSION}"
            cd /
            return 1
        fi

        # Run 4-tier verification
        local verify_rc=0
        verify_download "tool" "terragrunt" "$TERRAGRUNT_VERSION" "terragrunt" "$ARCH" || verify_rc=$?
        if [ "$verify_rc" -eq 1 ]; then
            log_error "Verification failed for Terragrunt ${TERRAGRUNT_VERSION}"
            cd /
            return 1
        fi

        log_message "✓ Terragrunt v${TERRAGRUNT_VERSION} verified successfully"

        # Install the verified binary
        log_command "Installing Terragrunt binary" \
            command mv terragrunt /usr/local/bin/terragrunt

        log_command "Setting Terragrunt permissions" \
            chmod +x /usr/local/bin/terragrunt

        cd /
    else
        log_warning "Terragrunt not available for architecture $(dpkg --print-architecture), skipping..."
    fi
}

# ============================================================================
# terraform-docs Installation
# ============================================================================
install_terraform_docs() {
    log_message "Installing terraform-docs ${TFDOCS_VERSION}..."

    local ARCH
    ARCH=$(map_arch_or_skip "amd64" "arm64")
    if [ -z "$ARCH" ]; then
        log_warning "terraform-docs not available for architecture $(dpkg --print-architecture), skipping..."
        return 0
    fi

    local TFDOCS_ARCHIVE="terraform-docs-v${TFDOCS_VERSION}-linux-${ARCH}.tar.gz"
    local TFDOCS_URL="https://github.com/terraform-docs/terraform-docs/releases/download/v${TFDOCS_VERSION}/${TFDOCS_ARCHIVE}"

    log_message "Installing terraform-docs v${TFDOCS_VERSION} for ${ARCH}..."

    # Register Tier 3 fetcher for terraform-docs
    _fetch_terraform_docs_checksum() {
        local _ver="$1"
        local _arch="$2"
        local _archive="terraform-docs-v${_ver}-linux-${_arch}.tar.gz"
        local _url="https://github.com/terraform-docs/terraform-docs/releases/download/v${_ver}/terraform-docs-v${_ver}.sha256sum"
        fetch_github_checksums_txt "$_url" "$_archive" 2>/dev/null
    }
    register_tool_checksum_fetcher "terraform-docs" "_fetch_terraform_docs_checksum"

    # Download terraform-docs
    local BUILD_TEMP
    BUILD_TEMP=$(create_secure_temp_dir)
    cd "$BUILD_TEMP" || return 1
    log_message "Downloading terraform-docs..."
    if ! command curl -L -f --retry 3 --retry-delay 2 --retry-all-errors --progress-bar -o "terraform-docs.tar.gz" "$TFDOCS_URL"; then
        log_error "Failed to download terraform-docs ${TFDOCS_VERSION}"
        cd /
        return 1
    fi

    # Run 4-tier verification
    local verify_rc=0
    verify_download "tool" "terraform-docs" "$TFDOCS_VERSION" "terraform-docs.tar.gz" "$ARCH" || verify_rc=$?
    if [ "$verify_rc" -eq 1 ]; then
        log_error "Verification failed for terraform-docs ${TFDOCS_VERSION}"
        cd /
        return 1
    fi

    # Extract and install
    log_command "Extracting terraform-docs" \
        tar -xzf terraform-docs.tar.gz

    log_command "Installing terraform-docs binary" \
        command mv ./terraform-docs /usr/local/bin/

    log_command "Setting terraform-docs permissions" \
        chmod +x /usr/local/bin/terraform-docs

    log_message "✓ terraform-docs v${TFDOCS_VERSION} installed successfully"

    cd /
}

# ============================================================================
# tflint Installation
# ============================================================================
install_tflint() {
    log_message "Installing tflint ${TFLINT_VERSION}..."

    local ARCH
    ARCH=$(map_arch_or_skip "amd64" "arm64")
    if [ -z "$ARCH" ]; then
        log_warning "tflint not available for architecture $(dpkg --print-architecture), skipping..."
        return 0
    fi

    local TFLINT_ARCHIVE="tflint_linux_${ARCH}.zip"
    local TFLINT_URL="https://github.com/terraform-linters/tflint/releases/download/v${TFLINT_VERSION}/${TFLINT_ARCHIVE}"

    log_message "Installing tflint v${TFLINT_VERSION} for ${ARCH}..."

    # Register Tier 3 fetcher for tflint
    _fetch_tflint_checksum() {
        local _ver="$1"
        local _arch="$2"
        local _archive="tflint_linux_${_arch}.zip"
        local _url="https://github.com/terraform-linters/tflint/releases/download/v${_ver}/checksums.txt"
        fetch_github_checksums_txt "$_url" "$_archive" 2>/dev/null
    }
    register_tool_checksum_fetcher "tflint" "_fetch_tflint_checksum"

    # Download tflint
    local BUILD_TEMP
    BUILD_TEMP=$(create_secure_temp_dir)
    cd "$BUILD_TEMP" || return 1
    log_message "Downloading tflint..."
    if ! command curl -L -f --retry 3 --retry-delay 2 --retry-all-errors --progress-bar -o "$TFLINT_ARCHIVE" "$TFLINT_URL"; then
        log_error "Failed to download tflint ${TFLINT_VERSION}"
        cd /
        return 1
    fi

    # Run 4-tier verification
    local verify_rc=0
    verify_download "tool" "tflint" "$TFLINT_VERSION" "$TFLINT_ARCHIVE" "$ARCH" || verify_rc=$?
    if [ "$verify_rc" -eq 1 ]; then
        log_error "Verification failed for tflint ${TFLINT_VERSION}"
        cd /
        return 1
    fi

    # Extract zip file
    log_command "Extracting tflint" \
        unzip -o "$TFLINT_ARCHIVE"

    # Install binary
    log_command "Installing tflint binary" \
        install -c -v ./tflint /usr/local/bin/

    log_message "✓ tflint v${TFLINT_VERSION} installed successfully"

    cd /
}

# ============================================================================
# Trivy Installation (Security Scanner) - via APT repository
# ============================================================================
install_trivy() {
    # Note: tfsec has been deprecated and merged into Trivy.
    # See: https://github.com/aquasecurity/tfsec/discussions/1994
    # Trivy is installed via the official APT repository at get.trivy.dev
    # (GitHub binary releases are no longer available)
    log_message "Installing Trivy via APT repository..."

    # Add Trivy GPG key and repository
    add_apt_repository_key "Trivy" \
        "https://get.trivy.dev/deb/public.key" \
        "/usr/share/keyrings/trivy.gpg" \
        "/etc/apt/sources.list.d/trivy.list" \
        "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://get.trivy.dev/deb generic main"

    # Update package lists with new repository
    apt_update

    # Install Trivy
    apt_install trivy

    if command -v trivy &> /dev/null; then
        log_message "✓ Trivy installed successfully via APT"
    else
        log_error "Trivy installation failed"
        return 1
    fi
}
