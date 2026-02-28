#!/bin/bash
# AWS CLI v2 - Official Amazon Web Services command-line interface
#
# Description:
#   Installs AWS CLI version 2 with Session Manager plugin for comprehensive
#   AWS service management from the command line. Includes helpers for profile
#   management, role assumption, and credential configuration.
#
# Security:
#   - GPG signature verification of AWS CLI installer
#   - AWS public key imported from keyserver and fingerprint verified
#   - Installation fails if signature verification fails
#
# Features:
#   - AWS CLI v2: Complete AWS service management
#   - Session Manager Plugin: Secure EC2 instance access
#   - Built-in auto-prompt and command completion
#   - AWS SSO and IAM Identity Center support
#   - Enhanced output formatting (table, json, yaml)
#   - Profile management helpers
#
# Tools Installed:
#   - aws: AWS CLI v2 (latest stable)
#   - session-manager-plugin: AWS Systems Manager Session Manager
#
# Common Commands:
#   - aws configure: Set up credentials and default region
#   - aws sts get-caller-identity: Verify authentication
#   - aws s3 ls: List S3 buckets
#   - aws ec2 describe-instances: List EC2 instances
#
# Environment Variables:
#   - AWS_PROFILE: Active AWS profile
#   - AWS_ACCESS_KEY_ID: Access key (use profiles instead)
#   - AWS_SECRET_ACCESS_KEY: Secret key (use profiles instead)
#   - AWS_REGION: Default AWS region
#   - AWS_DEFAULT_REGION: Alternative region setting
#
# Note:
#   For security, use AWS profiles (~/.aws/credentials) or IAM roles instead
#   of environment variables for credentials. SSO is recommended for organizations.
#
set -euo pipefail

# Source standard feature header for user handling
source /tmp/build-scripts/base/feature-header.sh

# Source apt utilities for reliable package installation
source /tmp/build-scripts/base/apt-utils.sh

# Source download verification utilities for secure binary downloads
source /tmp/build-scripts/base/download-verify.sh

# Source checksum utilities for secure binary downloads
source /tmp/build-scripts/base/checksum-fetch.sh

# Source 4-tier checksum verification system
source /tmp/build-scripts/base/checksum-verification.sh

# Start logging
log_feature_start "AWS CLI v2"

# ============================================================================
# Dependencies Installation
# ============================================================================
log_message "Installing dependencies..."

# Update package lists with retry logic
apt_update

# Install required system packages with retry logic
log_message "Installing required packages..."
apt_install \
        unzip \
        groff \
        less \
        gpg \
        curl \
        ca-certificates

# ============================================================================
# AWS CLI v2 Installation
# ============================================================================
log_message "Installing AWS CLI v2..."

# Detect architecture
ARCH=$(dpkg --print-architecture)
AWS_ARCH=$(map_arch "x86_64" "aarch64") || {
    log_warning "AWS CLI not available for architecture $ARCH"
    exit 1
}
AWS_CLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}.zip"

BUILD_TEMP=$(create_secure_temp_dir)
cd "$BUILD_TEMP"

# ============================================================================
# GPG Key Import and Verification
# ============================================================================
log_message "Importing AWS CLI GPG public key..."

# AWS CLI v2 public key fingerprint
# Source: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
AWS_CLI_KEY_ID="A6310ACC4672475C"
AWS_CLI_KEY_FINGERPRINT="FB5D B77F D5C1 18B8 0511  ADA8 A631 0ACC 4672 475C"

# Import AWS public key from keyserver
log_command "Importing AWS public key from keyserver" \
    gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys "${AWS_CLI_KEY_ID}" || \
    gpg --keyserver hkps://keys.openpgp.org --recv-keys "${AWS_CLI_KEY_ID}"

# Verify key fingerprint
log_message "Verifying key fingerprint..."
IMPORTED_FINGERPRINT=$(gpg --fingerprint "${AWS_CLI_KEY_ID}" 2>/dev/null | command grep -oP '[A-Fa-f0-9]{4}( +[A-Fa-f0-9]{4}){9}' | command tr -d ' ' | command tr '[:lower:]' '[:upper:]')
EXPECTED_FINGERPRINT=$(echo "${AWS_CLI_KEY_FINGERPRINT}" | command tr -d ' ' | command tr '[:lower:]' '[:upper:]')

if [ "$IMPORTED_FINGERPRINT" != "$EXPECTED_FINGERPRINT" ]; then
    log_error "GPG key fingerprint mismatch!"
    log_error "Expected: ${EXPECTED_FINGERPRINT}"
    log_error "Got:      ${IMPORTED_FINGERPRINT}"
    exit 1
fi

log_message "✓ AWS CLI GPG key verified"

# ============================================================================
# Download and Verify AWS CLI v2
# ============================================================================
log_command "Downloading AWS CLI v2" \
    command curl -sL "$AWS_CLI_URL" -o "awscliv2.zip"

log_command "Downloading AWS CLI v2 signature" \
    command curl -sL "${AWS_CLI_URL}.sig" -o "awscliv2.sig"

log_message "Verifying GPG signature..."
if ! gpg --verify awscliv2.sig awscliv2.zip 2>/dev/null; then
    log_error "GPG signature verification failed!"
    log_error "The downloaded AWS CLI package may be compromised."
    command rm -f awscliv2.zip awscliv2.sig
    exit 1
fi

log_message "✓ AWS CLI v2 signature verified"

# Run 4-tier verification for unified logging (GPG already verified above)
# No fetcher registered — the GPG verification above is stronger than Tier 3
verify_rc=0
verify_download "tool" "aws-cli" "latest" "awscliv2.zip" "$ARCH" || verify_rc=$?
# We don't fail on verify_rc since we already verified with GPG above

log_command "Extracting AWS CLI v2" \
    unzip -q awscliv2.zip

log_command "Installing AWS CLI v2" \
    ./aws/install

cd /
log_command "Cleaning up build directory" \
    command rm -rf "$BUILD_TEMP"

# ============================================================================
# Session Manager Plugin Installation
# ============================================================================
log_message "Installing AWS Session Manager plugin..."

# Download architecture-specific package
SM_DIR=$(map_arch_or_skip "ubuntu_64bit" "ubuntu_arm64")
if [ -n "$SM_DIR" ]; then
    SESSION_MANAGER_URL="https://s3.amazonaws.com/session-manager-downloads/plugin/latest/${SM_DIR}/session-manager-plugin.deb"
else
    log_warning "Session Manager plugin not available for architecture $ARCH"
    SESSION_MANAGER_URL=""
fi

if [ -n "$SESSION_MANAGER_URL" ]; then
    # Session Manager doesn't publish checksums — will be TOFU with unified logging
    BUILD_TEMP=$(create_secure_temp_dir)
    cd "$BUILD_TEMP"
    log_message "Downloading Session Manager plugin for ${ARCH}..."
    if ! command curl -L -f --retry 3 --retry-delay 2 --retry-all-errors --progress-bar -o "session-manager-plugin.deb" "$SESSION_MANAGER_URL"; then
        log_error "Failed to download Session Manager plugin"
        cd /
        log_feature_end
        exit 1
    fi

    # Run 4-tier verification (TOFU — no published checksums)
    verify_rc=0
    verify_download "tool" "session-manager-plugin" "latest" "session-manager-plugin.deb" "$ARCH" || verify_rc=$?
    if [ "$verify_rc" -eq 1 ]; then
        log_error "Verification failed for Session Manager plugin"
        cd /
        log_feature_end
        exit 1
    fi

    log_command "Installing Session Manager plugin" \
        dpkg -i session-manager-plugin.deb

    cd /
    log_command "Cleaning up build directory" \
        command rm -rf "$BUILD_TEMP"
fi

# ============================================================================
# Environment Configuration
# ============================================================================
log_message "Configuring AWS environment..."

# Ensure /etc/bashrc.d exists
log_command "Creating bashrc.d directory" \
    mkdir -p /etc/bashrc.d

# Create system-wide AWS configuration (content in lib/bashrc/aws.sh)
write_bashrc_content /etc/bashrc.d/50-aws.sh "AWS CLI configuration" \
    < /tmp/build-scripts/features/lib/bashrc/aws.sh

log_command "Setting AWS bashrc script permissions" \
    chmod +x /etc/bashrc.d/50-aws.sh

# ============================================================================
# Container Startup Scripts
# ============================================================================
log_message "Creating AWS startup scripts..."

# Create startup directory if it doesn't exist
log_command "Creating container startup directory" \
    mkdir -p /etc/container/first-startup

command cat > /etc/container/first-startup/20-aws-setup.sh << EOF
#!/bin/bash
# Check for AWS credentials
if [ ! -f ~/.aws/credentials ] && [ -f ${WORKING_DIR}/.aws/credentials ]; then
    echo "=== AWS Configuration ==="
    echo "Linking workspace AWS credentials..."
    mkdir -p ~/.aws
    ln -s ${WORKING_DIR}/.aws/credentials ~/.aws/credentials
    ln -s ${WORKING_DIR}/.aws/config ~/.aws/config 2>/dev/null || true
fi

# Check if AWS CLI is configured
if command -v aws &> /dev/null; then
    if aws sts get-caller-identity &> /dev/null; then
        echo "AWS CLI is configured and authenticated"
    else
        echo "AWS CLI is installed but not configured"
        echo "Run 'aws configure' to set up your credentials"
    fi
fi
EOF

log_command "Setting AWS startup script permissions" \
    chmod +x /etc/container/first-startup/20-aws-setup.sh

# ============================================================================
# Verification Script
# ============================================================================
log_message "Creating AWS verification script..."

command cat > /usr/local/bin/test-aws << 'EOF'
#!/bin/bash
echo "=== AWS CLI Status ==="
if command -v aws &> /dev/null; then
    echo "✓ AWS CLI is installed"
    echo "  Version: $(aws --version 2>&1 | head -1)"
    echo "  Binary: $(which aws)"
else
    echo "✗ AWS CLI is not installed"
    exit 1
fi

echo ""
echo "=== Session Manager Plugin ==="
if command -v session-manager-plugin &> /dev/null; then
    echo "✓ Session Manager plugin is installed"
    echo "  Binary: $(which session-manager-plugin)"
else
    echo "✗ Session Manager plugin is not installed"
fi

echo ""
echo "=== AWS Configuration ==="
if [ -f ~/.aws/credentials ] || [ -f ~/.aws/config ]; then
    echo "✓ AWS configuration files found"
    [ -f ~/.aws/credentials ] && echo "  Credentials: ~/.aws/credentials"
    [ -f ~/.aws/config ] && echo "  Config: ~/.aws/config"
else
    echo "✗ No AWS configuration files found"
fi

echo ""
echo "=== Current Identity ==="
if aws sts get-caller-identity &>/dev/null 2>&1; then
    echo "✓ AWS credentials are configured"
    aws sts get-caller-identity --output table
else
    echo "✗ AWS credentials not configured or invalid"
    echo "  Run 'aws configure' to set up credentials"
fi

echo ""
echo "=== Available Profiles ==="
if command -v aws &> /dev/null; then
    aws configure list-profiles 2>/dev/null || echo "No profiles configured"
fi
EOF

log_command "Setting test-aws permissions" \
    chmod +x /usr/local/bin/test-aws

# ============================================================================
# Final Verification
# ============================================================================
log_message "Verifying AWS CLI installation..."

log_command "Checking AWS CLI version" \
    aws --version || log_warning "AWS CLI not installed properly"

if command -v session-manager-plugin &> /dev/null; then
    log_command "Checking Session Manager plugin" \
        session-manager-plugin || log_warning "Session Manager plugin verification failed"
fi

# Log feature summary
log_feature_summary \
    --feature "AWS CLI" \
    --tools "aws,session-manager-plugin" \
    --paths "$HOME/.aws" \
    --env "AWS_PROFILE,AWS_REGION,AWS_DEFAULT_REGION,AWS_ACCESS_KEY_ID,AWS_SECRET_ACCESS_KEY" \
    --commands "aws,session-manager-plugin,awsprofile,awswho,aws-profile,aws-assume-role" \
    --next-steps "Run 'test-aws' to verify installation. Configure with 'aws configure' or use aws-profile helpers."

# End logging
log_feature_end

echo ""
echo "Run 'test-aws' to verify installation"
echo "Run 'check-build-logs.sh aws' to review installation logs"
