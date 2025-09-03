#!/bin/bash
# AWS CLI v2 - Official Amazon Web Services command-line interface
#
# Description:
#   Installs AWS CLI version 2 with Session Manager plugin for comprehensive
#   AWS service management from the command line. Includes helpers for profile
#   management, role assumption, and credential configuration.
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
        less

# ============================================================================
# AWS CLI v2 Installation
# ============================================================================
log_message "Installing AWS CLI v2..."

# Detect architecture
ARCH=$(dpkg --print-architecture)
if [ "$ARCH" = "amd64" ]; then
    AWS_CLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
elif [ "$ARCH" = "arm64" ]; then
    AWS_CLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip"
else
    log_warning "AWS CLI not available for architecture $ARCH"
    exit 1
fi

log_command "Changing to temporary directory" \
    cd /tmp

log_command "Downloading AWS CLI v2" \
    curl -sL "$AWS_CLI_URL" -o "awscliv2.zip"

log_command "Extracting AWS CLI v2" \
    unzip -q awscliv2.zip

log_command "Installing AWS CLI v2" \
    ./aws/install

log_command "Cleaning up AWS CLI installer" \
    rm -rf awscliv2.zip aws/

log_command "Returning to root directory" \
    cd /

# ============================================================================
# Session Manager Plugin Installation
# ============================================================================
log_message "Installing AWS Session Manager plugin..."

# Download architecture-specific package
if [ "$ARCH" = "amd64" ]; then
    SESSION_MANAGER_URL="https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb"
elif [ "$ARCH" = "arm64" ]; then
    SESSION_MANAGER_URL="https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_arm64/session-manager-plugin.deb"
else
    log_warning "Session Manager plugin not available for architecture $ARCH"
    SESSION_MANAGER_URL=""
fi

if [ -n "$SESSION_MANAGER_URL" ]; then
    log_command "Downloading Session Manager plugin" \
        curl -sL "$SESSION_MANAGER_URL" -o "/tmp/session-manager-plugin.deb"

    log_command "Installing Session Manager plugin" \
        dpkg -i /tmp/session-manager-plugin.deb

    log_command "Cleaning up Session Manager installer" \
        rm -f /tmp/session-manager-plugin.deb
fi

# ============================================================================
# Environment Configuration
# ============================================================================
log_message "Configuring AWS environment..."

# Ensure /etc/bashrc.d exists
log_command "Creating bashrc.d directory" \
    mkdir -p /etc/bashrc.d

# Create system-wide AWS configuration
write_bashrc_content /etc/bashrc.d/50-aws.sh "AWS CLI configuration" << 'AWS_BASHRC_EOF'
# ----------------------------------------------------------------------------
# AWS CLI Configuration and Helpers
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

# ----------------------------------------------------------------------------
# AWS CLI Aliases - Common AWS operations
# ----------------------------------------------------------------------------
alias awsprofile='aws configure list-profiles'     # List available profiles
alias awswho='aws sts get-caller-identity'        # Show current identity
alias awsregion='aws configure get region'        # Show current region
alias awsls='aws s3 ls'                          # List S3 buckets/objects
alias awsec2='aws ec2 describe-instances --query "Reservations[*].Instances[*].[InstanceId,State.Name,Tags[?Key==\`Name\`].Value|[0]]" --output table'
alias awslogs='aws logs tail'                    # Tail CloudWatch logs

# AWS CLI auto-completion
if command -v aws_completer &> /dev/null; then
    complete -C aws_completer aws
fi

# ----------------------------------------------------------------------------
# aws-profile - Switch between AWS profiles or show current profile
#
# Arguments:
#   $1 - Profile name (optional)
#
# Examples:
#   aws-profile              # Show current profile and list available
#   aws-profile production   # Switch to production profile
# ----------------------------------------------------------------------------
aws-profile() {
    if [ -z "$1" ]; then
        echo "Current profile: $AWS_PROFILE"
        echo "Available profiles:"
        aws configure list-profiles
    else
        export AWS_PROFILE="$1"
        echo "Switched to AWS profile: $AWS_PROFILE"
        aws sts get-caller-identity
    fi
}

# ----------------------------------------------------------------------------
# aws-assume-role - Assume an IAM role and export temporary credentials
#
# Arguments:
#   $1 - Role ARN (required)
#   $2 - Session name (optional)
#
# Example:
#   aws-assume-role arn:aws:iam::123456789012:role/MyRole
# ----------------------------------------------------------------------------
aws-assume-role() {
    if [ -z "$1" ]; then
        echo "Usage: aws-assume-role <role-arn> [session-name]"
        return 1
    fi

    local role_arn="$1"
    local session_name="${2:-cli-session-$(date +%s)}"

    local creds=$(aws sts assume-role \
        --role-arn "$role_arn" \
        --role-session-name "$session_name" \
        --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
        --output text)

    export AWS_ACCESS_KEY_ID=$(echo $creds | awk '{print $1}')
    export AWS_SECRET_ACCESS_KEY=$(echo $creds | awk '{print $2}')
    export AWS_SESSION_TOKEN=$(echo $creds | awk '{print $3}')

    echo "Assumed role: $role_arn"
    aws sts get-caller-identity
}

# ----------------------------------------------------------------------------
# aws-regions - List all AWS regions or set default region
#
# Arguments:
#   $1 - Region code (optional)
#
# Examples:
#   aws-regions              # List all regions
#   aws-regions us-west-2    # Set default region
# ----------------------------------------------------------------------------
aws-regions() {
    if [ -z "$1" ]; then
        echo "Current region: $(aws configure get region || echo 'Not set')"
        echo
        echo "Available regions:"
        aws ec2 describe-regions --query 'Regions[*].[RegionName,Endpoint]' --output table
    else
        aws configure set region "$1"
        echo "Default region set to: $1"
    fi
}

# ----------------------------------------------------------------------------
# aws-mfa - Generate MFA session tokens
#
# Arguments:
#   $1 - MFA device ARN (required)
#   $2 - MFA token code (required)
#
# Example:
#   aws-mfa arn:aws:iam::123456789012:mfa/user 123456
# ----------------------------------------------------------------------------
aws-mfa() {
    if [ -z "$1" ] || [ -z "$2" ]; then
        echo "Usage: aws-mfa <mfa-device-arn> <token-code>"
        return 1
    fi

    local mfa_arn="$1"
    local token_code="$2"

    local creds=$(aws sts get-session-token \
        --serial-number "$mfa_arn" \
        --token-code "$token_code" \
        --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
        --output text)

    export AWS_ACCESS_KEY_ID=$(echo $creds | awk '{print $1}')
    export AWS_SECRET_ACCESS_KEY=$(echo $creds | awk '{print $2}')
    export AWS_SESSION_TOKEN=$(echo $creds | awk '{print $3}')

    echo "MFA session established"
    aws sts get-caller-identity
}

# ----------------------------------------------------------------------------
# aws-sso-login - Simplified SSO login
#
# Arguments:
#   $1 - Profile name (optional, uses AWS_PROFILE if not specified)
#
# Example:
#   aws-sso-login mycompany-dev
# ----------------------------------------------------------------------------
aws-sso-login() {
    local profile="${1:-${AWS_PROFILE:-default}}"
    export AWS_PROFILE="$profile"
    aws sso login --profile "$profile"
    echo "SSO login complete for profile: $profile"
    aws sts get-caller-identity
}

# AWS CLI auto-completion
if command -v aws_completer &> /dev/null; then
    complete -C aws_completer aws
fi

# Clean up helper functions
unset -f _check_command 2>/dev/null || true

# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
AWS_BASHRC_EOF

log_command "Setting AWS bashrc script permissions" \
    chmod +x /etc/bashrc.d/50-aws.sh

# ============================================================================
# Container Startup Scripts
# ============================================================================
log_message "Creating AWS startup scripts..."

# Create startup directory if it doesn't exist
log_command "Creating container startup directory" \
    mkdir -p /etc/container/first-startup

cat > /etc/container/first-startup/20-aws-setup.sh << EOF
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

cat > /usr/local/bin/test-aws << 'EOF'
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

# End logging
log_feature_end

echo ""
echo "Run 'test-aws' to verify installation"
echo "Run 'check-build-logs.sh aws' to review installation logs"
