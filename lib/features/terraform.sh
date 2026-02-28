#!/bin/bash
# Terraform Infrastructure as Code Setup
#
# Description:
#   Installs Terraform and essential tools for infrastructure as code development,
#   including Terragrunt for DRY configurations, terraform-docs for documentation,
#   tflint for code quality checks, and Trivy for security scanning. Configures
#   plugin caching for optimal performance in containerized environments.
#
# Features:
#   - Official Terraform CLI from HashiCorp
#   - Terragrunt for managing Terraform configurations at scale
#   - terraform-docs for automatic documentation generation
#   - tflint for Terraform linting and best practices
#   - Trivy for security vulnerability scanning (replaces deprecated tfsec)
#   - Intelligent plugin cache configuration
#   - Shell aliases and helper functions
#   - Auto-initialization for Terraform projects
#
# Tools Installed:
#   - Terraform (latest from HashiCorp APT repository)
#   - Terragrunt (infrastructure as code wrapper)
#   - terraform-docs (documentation generator)
#   - tflint (linter for Terraform)
#   - Trivy (security scanner - replaces deprecated tfsec)
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
#   trivy fs .                 # Security scan Terraform files
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

# Source retry utilities for network operations
source /tmp/build-scripts/base/retry-utils.sh

# Source checksum utilities for secure binary downloads
source /tmp/build-scripts/base/checksum-fetch.sh

# Source download verification utilities
source /tmp/build-scripts/base/download-verify.sh
source /tmp/build-scripts/base/cache-utils.sh

# Source secure temp directory utilities

# Start logging
log_feature_start "Terraform"

# Version configuration
# Terraform uses latest from HashiCorp APT repository
# TERRAFORM_VERSION is not used since we install from APT (always latest)
TERRAGRUNT_VERSION="${TERRAGRUNT_VERSION:-0.93.0}"
TFDOCS_VERSION="${TFDOCS_VERSION:-0.20.0}"
TFLINT_VERSION="${TFLINT_VERSION:-0.59.1}"
TRIVY_VERSION="${TRIVY_VERSION:-0.69.1}"

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

# Note: Terraform is installed via HashiCorp APT repository which handles GPG
# signature verification automatically. For direct binary downloads (if needed),
# the download_and_verify_terraform_gpg() function in signature-verify.sh provides
# GPG verification using HashiCorp's signing key and SHA256SUMS files.

# Add HashiCorp GPG key and repository
# Uses add_apt_repository_key() for Debian version compatibility (apt-key vs signed-by)
add_apt_repository_key "HashiCorp" \
    "https://apt.releases.hashicorp.com/gpg" \
    "/usr/share/keyrings/hashicorp-archive-keyring.gpg" \
    "/etc/apt/sources.list.d/hashicorp.list" \
    "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main"

# Install Terraform
# Update package lists with retry logic
apt_update

log_message "Installing Terraform"
apt_install terraform

# ============================================================================
# Additional Tools Installation
# ============================================================================
log_message "Installing additional Terraform tools..."

# Source tool installation functions
source /tmp/build-scripts/features/lib/terraform/install-tools.sh

install_terragrunt
install_terraform_docs
install_tflint
install_trivy

# ============================================================================
# Cache Configuration
# ============================================================================
log_message "Configuring Terraform plugin cache..."

# ALWAYS use /cache paths for consistency
# This will either use cache mount (faster rebuilds) or be created in the image
TF_PLUGIN_CACHE="/cache/terraform"
log_message "Terraform plugin cache path: ${TF_PLUGIN_CACHE}"

# Create plugin cache directory with correct ownership
create_cache_directories "${TF_PLUGIN_CACHE}"

# ============================================================================
# Environment Configuration
# ============================================================================
log_message "Configuring Terraform environment..."

# Ensure /etc/bashrc.d exists
log_command "Creating bashrc.d directory" \
    mkdir -p /etc/bashrc.d

# Create system-wide Terraform configuration (content in lib/bashrc/terraform.sh)
write_bashrc_content /etc/bashrc.d/55-terraform.sh "Terraform configuration" \
    < /tmp/build-scripts/features/lib/bashrc/terraform.sh

log_command "Setting Terraform bashrc script permissions" \
    chmod +x /etc/bashrc.d/55-terraform.sh

# ============================================================================
# Container Startup Scripts
# ============================================================================
log_message "Creating Terraform startup scripts..."

# Create startup directory if it doesn't exist
log_command "Creating container startup directory" \
    mkdir -p /etc/container/first-startup

install -m 755 /tmp/build-scripts/features/lib/terraform/20-terraform-setup.sh \
    /etc/container/first-startup/20-terraform-setup.sh

# ============================================================================
# Verification Script
# ============================================================================
log_message "Creating Terraform verification script..."

install -m 755 /tmp/build-scripts/features/lib/terraform/test-terraform.sh \
    /usr/local/bin/test-terraform

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

if command -v trivy &> /dev/null; then
    log_command "Checking Trivy version" \
        trivy --version || log_warning "Trivy version check failed"
fi

# Log feature summary
log_feature_summary \
    --feature "Terraform" \
    --tools "terraform,terraform-docs,tflint,trivy" \
    --paths "$HOME/.terraform.d,$HOME/.tflint.d" \
    --env "TF_DATA_DIR,TF_LOG,TF_LOG_PATH" \
    --commands "terraform,tf,tfi,tfp,tfa,tfd,terraform-docs,tflint,trivy,tf-workspace,tf-format-all,tf-validate-all" \
    --next-steps "Run 'test-terraform' to verify installation. Use 'tf init' to initialize, 'tf plan' to preview, 'tf apply' to deploy. Lint with 'tflint', security scan with 'trivy fs .'."

# End logging
log_feature_end

echo ""
echo "Run 'test-terraform' to verify installation"
echo "Run 'check-build-logs.sh terraform' to review installation logs"
