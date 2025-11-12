#!/bin/bash
# Terraform Infrastructure as Code Setup
#
# Description:
#   Installs Terraform and essential tools for infrastructure as code development,
#   including Terragrunt for DRY configurations, terraform-docs for documentation,
#   and tflint for code quality checks. Configures plugin caching for optimal
#   performance in containerized environments.
#
# Features:
#   - Official Terraform CLI from HashiCorp
#   - Terragrunt for managing Terraform configurations at scale
#   - terraform-docs for automatic documentation generation
#   - tflint for Terraform linting and best practices
#   - Intelligent plugin cache configuration
#   - Shell aliases and helper functions
#   - Auto-initialization for Terraform projects
#
# Tools Installed:
#   - Terraform (latest from HashiCorp APT repository)
#   - Terragrunt (infrastructure as code wrapper)
#   - terraform-docs (documentation generator)
#   - tflint (linter for Terraform)
#
# Common Commands:
#   terraform init              # Initialize Terraform working directory
#   terraform plan             # Show execution plan
#   terraform apply            # Apply infrastructure changes
#   terraform destroy          # Destroy infrastructure
#   terraform fmt              # Format Terraform files
#   terraform validate         # Validate configuration
#   terragrunt run-all plan    # Plan across multiple modules
#   terraform-docs markdown .  # Generate documentation
#   tflint                     # Lint Terraform files
#
# Environment Variables:
#   TF_PLUGIN_CACHE_DIR - Plugin cache directory (auto-configured)
#
# Note:
#   If /cache directory is available, Terraform plugins will be cached there
#   for persistence across container rebuilds. Shell aliases (tf, tg) are
#   configured for common commands.
#
set -euo pipefail

# Source standard feature header for user handling
source /tmp/build-scripts/base/feature-header.sh

# Source apt utilities for reliable package installation
source /tmp/build-scripts/base/apt-utils.sh

# Source checksum utilities for secure binary downloads
source /tmp/build-scripts/features/lib/checksum-fetch.sh

# Source download verification utilities
source /tmp/build-scripts/base/download-verify.sh

# Source secure temp directory utilities

# Start logging
log_feature_start "Terraform"

# Version configuration
# Terraform uses latest from HashiCorp APT repository
# TERRAFORM_VERSION is not used since we install from APT (always latest)
TERRAGRUNT_VERSION="${TERRAGRUNT_VERSION:-0.93.0}"
TFDOCS_VERSION="${TFDOCS_VERSION:-0.20.0}"
TFLINT_VERSION="${TFLINT_VERSION:-0.59.1}"

# ============================================================================
# Dependencies Installation
# ============================================================================
log_message "Installing dependencies..."

# Update package lists with retry logic
apt_update

# Install dependencies
log_message "Installing required packages"
apt_install gnupg software-properties-common

# ============================================================================
# Terraform Installation
# ============================================================================
log_message "Installing Terraform..."

# Add HashiCorp GPG key and repository
# Support both old (apt-key) and new (signed-by) methods for backwards compatibility
# - Debian 11 (Bullseye) and 12 (Bookworm): apt-key still available
# - Debian 13 (Trixie) and later: apt-key removed, use signed-by method

if command -v apt-key >/dev/null 2>&1; then
    # Old method for Debian 11/12 compatibility
    log_message "Using apt-key method (Debian 11/12)"
    log_command "Adding HashiCorp GPG key" \
        bash -c "curl -fsSL https://apt.releases.hashicorp.com/gpg | apt-key add -"

    log_command "Adding HashiCorp repository" \
        apt-add-repository "deb [arch=$(dpkg --print-architecture)] https://apt.releases.hashicorp.com $(lsb_release -cs) main"
else
    # New method for Debian 13+ (Trixie and later)
    log_message "Using signed-by method (Debian 13+)"
    log_command "Adding HashiCorp GPG key" \
        bash -c "curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg"

    log_command "Setting GPG key permissions" \
        chmod go+r /usr/share/keyrings/hashicorp-archive-keyring.gpg

    log_command "Adding HashiCorp repository" \
        bash -c 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" > /etc/apt/sources.list.d/hashicorp.list'
fi

# Install Terraform
# Update package lists with retry logic
apt_update

log_message "Installing Terraform"
apt_install terraform

# ============================================================================
# Additional Tools Installation
# ============================================================================
log_message "Installing additional Terraform tools..."

# Install Terragrunt (common Terraform wrapper)
log_message "Installing Terragrunt ${TERRAGRUNT_VERSION}..."
ARCH=$(dpkg --print-architecture)

if [ "$ARCH" = "amd64" ] || [ "$ARCH" = "arm64" ]; then
    TERRAGRUNT_BINARY="terragrunt_linux_${ARCH}"
    TERRAGRUNT_URL="https://github.com/gruntwork-io/terragrunt/releases/download/v${TERRAGRUNT_VERSION}/${TERRAGRUNT_BINARY}"

    # Fetch checksum dynamically from GitHub releases
    log_message "Fetching Terragrunt checksum from GitHub..."
    TERRAGRUNT_CHECKSUMS_URL="https://github.com/gruntwork-io/terragrunt/releases/download/v${TERRAGRUNT_VERSION}/SHA256SUMS"

    if ! TERRAGRUNT_CHECKSUM=$(fetch_github_checksums_txt "$TERRAGRUNT_CHECKSUMS_URL" "$TERRAGRUNT_BINARY" 2>/dev/null); then
        log_error "Failed to fetch checksum for Terragrunt ${TERRAGRUNT_VERSION}"
        log_error "Please verify version exists: https://github.com/gruntwork-io/terragrunt/releases/tag/v${TERRAGRUNT_VERSION}"
        log_feature_end
        exit 1
    fi

    log_message "Expected SHA256: ${TERRAGRUNT_CHECKSUM}"

    # Download and verify Terragrunt with checksum verification
    BUILD_TEMP=$(create_secure_temp_dir)
    cd "$BUILD_TEMP"
    log_message "Downloading and verifying Terragrunt..."
    download_and_verify \
        "$TERRAGRUNT_URL" \
        "$TERRAGRUNT_CHECKSUM" \
        "terragrunt"

    log_message "✓ Terragrunt v${TERRAGRUNT_VERSION} verified successfully"

    # Install the verified binary
    log_command "Installing Terragrunt binary" \
        mv terragrunt /usr/local/bin/terragrunt

    log_command "Setting Terragrunt permissions" \
        chmod +x /usr/local/bin/terragrunt

    cd /
else
    log_warning "Terragrunt not available for architecture $ARCH, skipping..."
fi

# ============================================================================
# terraform-docs Installation
# ============================================================================
log_message "Installing terraform-docs ${TFDOCS_VERSION}..."

# Detect architecture
ARCH=$(dpkg --print-architecture)

# Determine the correct archive filename
TFDOCS_ARCHIVE="terraform-docs-v${TFDOCS_VERSION}-linux-${ARCH}.tar.gz"
TFDOCS_URL="https://github.com/terraform-docs/terraform-docs/releases/download/v${TFDOCS_VERSION}/${TFDOCS_ARCHIVE}"

log_message "Installing terraform-docs v${TFDOCS_VERSION} for ${ARCH}..."

# Fetch checksum dynamically from GitHub releases
log_message "Fetching terraform-docs checksum from GitHub..."
TFDOCS_CHECKSUMS_URL="https://github.com/terraform-docs/terraform-docs/releases/download/v${TFDOCS_VERSION}/terraform-docs-v${TFDOCS_VERSION}.sha256sum"

if ! TFDOCS_CHECKSUM=$(fetch_github_checksums_txt "$TFDOCS_CHECKSUMS_URL" "$TFDOCS_ARCHIVE" 2>/dev/null); then
    log_error "Failed to fetch checksum for terraform-docs ${TFDOCS_VERSION}"
    log_error "Please verify version exists: https://github.com/terraform-docs/terraform-docs/releases/tag/v${TFDOCS_VERSION}"
    log_feature_end
    exit 1
fi

log_message "Expected SHA256: ${TFDOCS_CHECKSUM}"

# Download and extract with checksum verification
BUILD_TEMP=$(create_secure_temp_dir)
cd "$BUILD_TEMP"
log_message "Downloading and verifying terraform-docs..."
download_and_extract \
    "$TFDOCS_URL" \
    "$TFDOCS_CHECKSUM" \
    "."

# Install binary
log_command "Installing terraform-docs binary" \
    mv ./terraform-docs /usr/local/bin/

log_command "Setting terraform-docs permissions" \
    chmod +x /usr/local/bin/terraform-docs

log_message "✓ terraform-docs v${TFDOCS_VERSION} installed successfully"

cd /

# ============================================================================
# tflint Installation
# ============================================================================
log_message "Installing tflint ${TFLINT_VERSION}..."

# Determine the correct archive filename
TFLINT_ARCHIVE="tflint_linux_${ARCH}.zip"
TFLINT_URL="https://github.com/terraform-linters/tflint/releases/download/v${TFLINT_VERSION}/${TFLINT_ARCHIVE}"

log_message "Installing tflint v${TFLINT_VERSION} for ${ARCH}..."

# Fetch checksum dynamically from GitHub releases
log_message "Fetching tflint checksum from GitHub..."
TFLINT_CHECKSUMS_URL="https://github.com/terraform-linters/tflint/releases/download/v${TFLINT_VERSION}/checksums.txt"

if ! TFLINT_CHECKSUM=$(fetch_github_checksums_txt "$TFLINT_CHECKSUMS_URL" "$TFLINT_ARCHIVE" 2>/dev/null); then
    log_error "Failed to fetch checksum for tflint ${TFLINT_VERSION}"
    log_error "Please verify version exists: https://github.com/terraform-linters/tflint/releases/tag/v${TFLINT_VERSION}"
    log_feature_end
    exit 1
fi

log_message "Expected SHA256: ${TFLINT_CHECKSUM}"

# Download and verify with checksum
BUILD_TEMP=$(create_secure_temp_dir)
cd "$BUILD_TEMP"
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

# ============================================================================
# Cache Configuration
# ============================================================================
log_message "Configuring Terraform plugin cache..."

# ALWAYS use /cache paths for consistency
# This will either use cache mount (faster rebuilds) or be created in the image
TF_PLUGIN_CACHE="/cache/terraform"
log_message "Terraform plugin cache path: ${TF_PLUGIN_CACHE}"

# Create plugin cache directory with correct ownership
# This ensures it exists in the image even without cache mounts
# Use install -d for atomic directory creation with ownership
log_command "Creating plugin cache directory with ownership" \
    install -d -m 0755 -o "${USER_UID}" -g "${USER_GID}" "${TF_PLUGIN_CACHE}"

# ============================================================================
# Environment Configuration
# ============================================================================
log_message "Configuring Terraform environment..."

# Ensure /etc/bashrc.d exists
log_command "Creating bashrc.d directory" \
    mkdir -p /etc/bashrc.d

# Create system-wide Terraform configuration
write_bashrc_content /etc/bashrc.d/55-terraform.sh "Terraform configuration" << 'TERRAFORM_BASHRC_EOF'
# ----------------------------------------------------------------------------
# Terraform configuration
# ----------------------------------------------------------------------------

# Error protection for interactive shells
set +u  # Don't error on unset variables
set +e  # Don't exit on errors

# Check if we're in an interactive shell
if [[ $- != *i* ]]; then
    # Not interactive, skip loading
    return 0
fi

# Defensive programming - check for required commands
_check_command() {
    command -v "$1" >/dev/null 2>&1
}

# Terraform plugin cache location (may be in /cache for volume persistence)
export TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE}"

# Terraform aliases
alias tf='terraform'
alias tfi='terraform init'
alias tfp='terraform plan'
alias tfa='terraform apply'
alias tfd='terraform destroy'
alias tfv='terraform validate'
alias tff='terraform fmt'
alias tfs='terraform state'
alias tfw='terraform workspace'

# Terragrunt aliases
alias tg='terragrunt'
alias tgi='terragrunt init'
alias tgp='terragrunt plan'
alias tga='terragrunt apply'
alias tgd='terragrunt destroy'

# Terraform auto-completion
if command -v terraform &> /dev/null; then
    complete -C /usr/bin/terraform terraform
    complete -C /usr/bin/terraform tf
fi

# Helper function to clean Terraform cache
tf-clean() {
    find . -type d -name ".terraform" -exec rm -rf {} + 2>/dev/null || true
    find . -type f -name ".terraform.lock.hcl" -delete 2>/dev/null || true
    echo "Cleaned Terraform cache files"
}

# Helper function to format all Terraform files
tf-fmt-all() {
    find . -name "*.tf" -exec terraform fmt {} \;
    echo "Formatted all Terraform files"
}

# Clean up helper functions
unset -f _check_command 2>/dev/null || true

# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
TERRAFORM_BASHRC_EOF

log_command "Setting Terraform bashrc script permissions" \
    chmod +x /etc/bashrc.d/55-terraform.sh

# ============================================================================
# Container Startup Scripts
# ============================================================================
log_message "Creating Terraform startup scripts..."

# Create startup directory if it doesn't exist
log_command "Creating container startup directory" \
    mkdir -p /etc/container/first-startup

cat > /etc/container/first-startup/20-terraform-setup.sh << 'EOF'
#!/bin/bash
# Initialize Terraform if in a Terraform project
if [ -f ${WORKING_DIR}/main.tf ] || [ -f ${WORKING_DIR}/terraform.tf ]; then
    echo "=== Terraform Project Detected ==="
    cd ${WORKING_DIR}

    # Check if .terraform directory exists
    if [ ! -d .terraform ]; then
        echo "Running terraform init..."
        terraform init || echo "Terraform init failed, continuing..."
    fi

    # Run validation
    echo "Running terraform validate..."
    terraform validate || echo "Terraform validation failed, continuing..."
fi

# Check for Terragrunt
if [ -f ${WORKING_DIR}/terragrunt.hcl ]; then
    echo "=== Terragrunt Project Detected ==="
    echo "Run 'terragrunt init' to initialize"
fi
EOF

log_command "Setting Terraform startup script permissions" \
    chmod +x /etc/container/first-startup/20-terraform-setup.sh

# ============================================================================
# Verification Script
# ============================================================================
log_message "Creating Terraform verification script..."

cat > /usr/local/bin/test-terraform << 'EOF'
#!/bin/bash
echo "=== Terraform Status ==="
if command -v terraform &> /dev/null; then
    echo "✓ Terraform is installed"
    echo "  Version: $(terraform version -json 2>/dev/null | jq -r '.terraform_version' || terraform version | head -1)"
    echo "  Binary: $(which terraform)"
else
    echo "✗ Terraform is not installed"
    exit 1
fi

echo ""
echo "=== Additional Tools ==="
if command -v terragrunt &> /dev/null; then
    echo "✓ Terragrunt is installed"
    echo "  Version: $(terragrunt --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    echo "  Binary: $(which terragrunt)"
else
    echo "✗ Terragrunt is not installed"
fi

if command -v terraform-docs &> /dev/null; then
    echo "✓ terraform-docs is installed"
    echo "  Version: $(terraform-docs --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    echo "  Binary: $(which terraform-docs)"
else
    echo "✗ terraform-docs is not installed"
fi

if command -v tflint &> /dev/null; then
    echo "✓ tflint is installed"
    echo "  Version: $(tflint --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    echo "  Binary: $(which tflint)"
else
    echo "✗ tflint is not installed"
fi

echo ""
echo "=== Configuration ==="
echo "  TF_PLUGIN_CACHE_DIR: ${TF_PLUGIN_CACHE_DIR:-/cache/terraform}"
if [ -d "${TF_PLUGIN_CACHE_DIR:-/cache/terraform}" ]; then
    echo "  ✓ Plugin cache directory exists"
    # Count cached providers if any
    provider_count=$(find "${TF_PLUGIN_CACHE_DIR:-/cache/terraform}" -name "terraform-provider-*" 2>/dev/null | wc -l)
    if [ $provider_count -gt 0 ]; then
        echo "  Cached providers: $provider_count"
    fi
else
    echo "  ✗ Plugin cache directory not found"
fi

# Check for .terraformrc
if [ -f ~/.terraformrc ]; then
    echo "  ✓ .terraformrc file exists"
else
    echo "  ✗ .terraformrc file not found"
fi
EOF

log_command "Setting test-terraform permissions" \
    chmod +x /usr/local/bin/test-terraform

# ============================================================================
# Final Verification
# ============================================================================
log_message "Verifying Terraform installation..."

log_command "Checking Terraform version" \
    terraform version || log_warning "Terraform not installed properly"

if command -v terragrunt &> /dev/null; then
    log_command "Checking Terragrunt version" \
        terragrunt --version || log_warning "Terragrunt version check failed"
fi

if command -v terraform-docs &> /dev/null; then
    log_command "Checking terraform-docs version" \
        terraform-docs --version || log_warning "terraform-docs version check failed"
fi

if command -v tflint &> /dev/null; then
    log_command "Checking tflint version" \
        tflint --version || log_warning "tflint version check failed"
fi

# Log feature summary
log_feature_summary \
    --feature "Terraform" \
    --tools "terraform,terraform-docs,tflint,tfsec" \
    --paths "$HOME/.terraform.d,$HOME/.tflint.d" \
    --env "TF_DATA_DIR,TF_LOG,TF_LOG_PATH" \
    --commands "terraform,tf,tfi,tfp,tfa,tfd,terraform-docs,tflint,tfsec,tf-workspace,tf-format-all,tf-validate-all" \
    --next-steps "Run 'test-terraform' to verify installation. Use 'tf init' to initialize, 'tf plan' to preview, 'tf apply' to deploy. Lint with 'tflint', security scan with 'tfsec'."

# End logging
log_feature_end

echo ""
echo "Run 'test-terraform' to verify installation"
echo "Run 'check-build-logs.sh terraform' to review installation logs"
