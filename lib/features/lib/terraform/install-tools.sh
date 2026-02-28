#!/bin/bash
# Terraform companion tool installations: Terragrunt, terraform-docs, tflint, Trivy
#
# Expected variables from parent script:
#   TERRAGRUNT_VERSION, TFDOCS_VERSION, TFLINT_VERSION, TRIVY_VERSION
#
# Expected sourced utilities:
#   checksum-fetch.sh, download-verify.sh, retry-utils.sh
#
# Source this file from terraform.sh after Terraform is installed.

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

        # Fetch checksum dynamically from GitHub releases
        log_message "Fetching Terragrunt checksum from GitHub..."
        local TERRAGRUNT_CHECKSUMS_URL="https://github.com/gruntwork-io/terragrunt/releases/download/v${TERRAGRUNT_VERSION}/SHA256SUMS"

        local TERRAGRUNT_CHECKSUM
        if ! TERRAGRUNT_CHECKSUM=$(fetch_github_checksums_txt "$TERRAGRUNT_CHECKSUMS_URL" "$TERRAGRUNT_BINARY" 2>/dev/null); then
            log_error "Failed to fetch checksum for Terragrunt ${TERRAGRUNT_VERSION}"
            log_error "Please verify version exists: https://github.com/gruntwork-io/terragrunt/releases/tag/v${TERRAGRUNT_VERSION}"
            log_feature_end
            exit 1
        fi

        log_message "Expected SHA256: ${TERRAGRUNT_CHECKSUM}"

        # Download and verify Terragrunt with checksum verification
        local BUILD_TEMP
        BUILD_TEMP=$(create_secure_temp_dir)
        cd "$BUILD_TEMP" || return 1 || return 1
        log_message "Downloading and verifying Terragrunt..."
        download_and_verify \
            "$TERRAGRUNT_URL" \
            "$TERRAGRUNT_CHECKSUM" \
            "terragrunt"

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

    # Fetch checksum dynamically from GitHub releases
    log_message "Fetching terraform-docs checksum from GitHub..."
    local TFDOCS_CHECKSUMS_URL="https://github.com/terraform-docs/terraform-docs/releases/download/v${TFDOCS_VERSION}/terraform-docs-v${TFDOCS_VERSION}.sha256sum"

    local TFDOCS_CHECKSUM
    if ! TFDOCS_CHECKSUM=$(fetch_github_checksums_txt "$TFDOCS_CHECKSUMS_URL" "$TFDOCS_ARCHIVE" 2>/dev/null); then
        log_error "Failed to fetch checksum for terraform-docs ${TFDOCS_VERSION}"
        log_error "Please verify version exists: https://github.com/terraform-docs/terraform-docs/releases/tag/v${TFDOCS_VERSION}"
        log_feature_end
        exit 1
    fi

    log_message "Expected SHA256: ${TFDOCS_CHECKSUM}"

    # Download and extract with checksum verification
    local BUILD_TEMP
    BUILD_TEMP=$(create_secure_temp_dir)
    cd "$BUILD_TEMP" || return 1
    log_message "Downloading and verifying terraform-docs..."
    download_and_extract \
        "$TFDOCS_URL" \
        "$TFDOCS_CHECKSUM" \
        "."

    # Install binary
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

    # Fetch checksum dynamically from GitHub releases
    log_message "Fetching tflint checksum from GitHub..."
    local TFLINT_CHECKSUMS_URL="https://github.com/terraform-linters/tflint/releases/download/v${TFLINT_VERSION}/checksums.txt"

    local TFLINT_CHECKSUM
    if ! TFLINT_CHECKSUM=$(fetch_github_checksums_txt "$TFLINT_CHECKSUMS_URL" "$TFLINT_ARCHIVE" 2>/dev/null); then
        log_error "Failed to fetch checksum for tflint ${TFLINT_VERSION}"
        log_error "Please verify version exists: https://github.com/terraform-linters/tflint/releases/tag/v${TFLINT_VERSION}"
        log_feature_end
        exit 1
    fi

    log_message "Expected SHA256: ${TFLINT_CHECKSUM}"

    # Download and verify with checksum
    local BUILD_TEMP
    BUILD_TEMP=$(create_secure_temp_dir)
    cd "$BUILD_TEMP" || return 1
    log_message "Downloading and verifying tflint..."
    download_and_verify \
        "$TFLINT_URL" \
        "$TFLINT_CHECKSUM" \
        "$TFLINT_ARCHIVE"

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
# Trivy Installation (Security Scanner)
# ============================================================================
install_trivy() {
    # Note: tfsec has been deprecated and merged into Trivy.
    # See: https://github.com/aquasecurity/tfsec/discussions/1994
    log_message "Installing Trivy ${TRIVY_VERSION}..."

    # Trivy uses Linux_64bit for amd64 and Linux_ARM64 for arm64
    local TRIVY_ARCH
    TRIVY_ARCH=$(map_arch_or_skip "64bit" "ARM64")
    if [ -z "$TRIVY_ARCH" ]; then
        log_warning "Trivy not available for architecture $(dpkg --print-architecture), skipping..."
        return 0
    fi

    local TRIVY_ARCHIVE="trivy_${TRIVY_VERSION}_Linux-${TRIVY_ARCH}.tar.gz"
    local TRIVY_URL="https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/${TRIVY_ARCHIVE}"

    log_message "Installing Trivy v${TRIVY_VERSION} for $(dpkg --print-architecture)..."

    # Fetch checksum dynamically from GitHub releases
    log_message "Fetching Trivy checksum from GitHub..."
    local TRIVY_CHECKSUMS_URL="https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_checksums.txt"

    local TRIVY_CHECKSUM
    if ! TRIVY_CHECKSUM=$(fetch_github_checksums_txt "$TRIVY_CHECKSUMS_URL" "$TRIVY_ARCHIVE" 2>/dev/null); then
        log_error "Failed to fetch checksum for Trivy ${TRIVY_VERSION}"
        log_error "Please verify version exists: https://github.com/aquasecurity/trivy/releases/tag/v${TRIVY_VERSION}"
        log_feature_end
        exit 1
    fi

    log_message "Expected SHA256: ${TRIVY_CHECKSUM}"

    # Download and extract with checksum verification
    local BUILD_TEMP
    BUILD_TEMP=$(create_secure_temp_dir)
    cd "$BUILD_TEMP" || return 1
    log_message "Downloading and verifying Trivy..."
    download_and_extract \
        "$TRIVY_URL" \
        "$TRIVY_CHECKSUM" \
        "."

    # Install binary
    log_command "Installing Trivy binary" \
        install -c -v -m 755 ./trivy /usr/local/bin/trivy

    log_message "✓ Trivy v${TRIVY_VERSION} installed successfully"

    cd /
}
