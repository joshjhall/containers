#!/bin/bash
# 1Password CLI - Secure secrets management from the command line
#
# Description:
#   Installs the official 1Password Command Line Interface (op) for secure
#   password and secrets management. Enables programmatic access to vaults.
#
# Features:
#   - Secure vault access from terminal
#   - Secret retrieval for scripts and applications
#   - Integration with shell environments
#   - Support for service accounts and automation
#   - Multi-vault and multi-account management
#
# Architecture Support:
#   - amd64 (x86_64)
#   - arm64 (aarch64)
#   - armhf (32-bit ARM)
#
# Security Features:
#   - GPG-signed packages
#   - Debsig verification policy
#   - Encrypted local cache
#   - Biometric unlock support (when available)
#
# Common Commands:
#   - op signin: Authenticate to 1Password
#   - op vault list: List available vaults
#   - op item get: Retrieve items from vaults
#   - op inject: Inject secrets into config files
#
# Note:
#   Requires 1Password account. Visit https://1password.com/developers/cli
#   for documentation and account setup.
#
set -euo pipefail

# Source standard feature header for user handling
source /tmp/build-scripts/base/feature-header.sh

# Source apt utilities for reliable package installation
source /tmp/build-scripts/base/apt-utils.sh

# Source retry utilities for network operations
source /tmp/build-scripts/base/retry-utils.sh

# Start logging
log_feature_start "1Password CLI"

# ============================================================================
# Architecture Detection
# ============================================================================
log_message "Detecting system architecture..."

# Detect system architecture for correct package selection
ARCH=$(dpkg --print-architecture)
case ${ARCH} in
    amd64)
        OP_ARCH="amd64"
        ;;
    arm64|aarch64)
        OP_ARCH="arm64"
        ;;
    armhf)
        OP_ARCH="arm"
        ;;
    *)
        log_error "Unsupported architecture: ${ARCH}"
        log_feature_end
        exit 1
        ;;
esac

# ============================================================================
# Repository Configuration
# ============================================================================
log_message "Configuring 1Password repository..."

# Add 1Password GPG key for package verification
log_message "Adding 1Password GPG key"
retry_with_backoff curl -sS https://downloads.1password.com/linux/keys/1password.asc | \
    gpg --dearmor --output /usr/share/keyrings/1password-archive-keyring.gpg

# Add 1Password repository
log_command "Adding 1Password repository" \
    bash -c "echo 'deb [arch=${ARCH} signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/${OP_ARCH} stable main' > /etc/apt/sources.list.d/1password.list"

# ============================================================================
# Security Policy Configuration
# ============================================================================
log_message "Configuring security policy for package verification..."

# Add the debsig-verify policy for additional package verification
log_command "Creating debsig policy directory" \
    mkdir -p /etc/debsig/policies/AC2D62742012EA22/
log_message "Downloading 1Password debsig policy"
retry_with_backoff curl -sS https://downloads.1password.com/linux/debian/debsig/1password.pol -o /etc/debsig/policies/AC2D62742012EA22/1password.pol
log_command "Creating debsig keyrings directory" \
    mkdir -p /usr/share/debsig/keyrings/AC2D62742012EA22
log_message "Adding 1Password debsig GPG key"
retry_with_backoff curl -sS https://downloads.1password.com/linux/keys/1password.asc | \
    gpg --dearmor --output /usr/share/debsig/keyrings/AC2D62742012EA22/debsig.gpg

# ============================================================================
# Package Installation
# ============================================================================
log_message "Installing 1Password CLI package..."

# Update package lists and install CLI
# Update package lists with retry logic
apt_update

log_message "Installing 1Password CLI"
apt_install 1password-cli

# ============================================================================
# Cache Configuration
# ============================================================================
log_message "Configuring 1Password cache directories..."

# ALWAYS use /cache paths for consistency with other tools
# 1Password CLI stores configuration and cache data
OP_CACHE_DIR="/cache/1password"
OP_CONFIG_DIR="/cache/1password/config"

# Create cache directories with correct ownership and permissions
# Note: config directory needs mode 0700 for security, so not using shared utility
# Use install -d for atomic directory creation with ownership
# Note: config directory needs mode 700 for security requirements
log_command "Creating 1Password cache directories with ownership" \
    bash -c "install -d -m 0755 -o '${USER_UID}' -g '${USER_GID}' '${OP_CACHE_DIR}' && install -d -m 0700 -o '${USER_UID}' -g '${USER_GID}' '${OP_CONFIG_DIR}'"

# ============================================================================
# System-wide Environment Configuration
# ============================================================================
log_message "Configuring system-wide 1Password environment..."

# Ensure /etc/bashrc.d exists
log_command "Creating bashrc.d directory" \
    mkdir -p /etc/bashrc.d

# Create system-wide 1Password configuration (content in lib/bashrc/op-cli.sh)
write_bashrc_content /etc/bashrc.d/70-1password.sh "1Password CLI configuration" \
    < /tmp/build-scripts/features/lib/bashrc/op-cli.sh

log_command "Setting 1Password bashrc script permissions" \
    chmod +x /etc/bashrc.d/70-1password.sh

# ============================================================================
# Container Startup Scripts
# ============================================================================
log_message "Creating 1Password startup script..."

# Create startup directory if it doesn't exist
log_command "Creating container startup directory" \
    mkdir -p /etc/container/first-startup

install -m 755 /tmp/build-scripts/features/lib/op-cli/50-1password-setup.sh \
    /etc/container/first-startup/50-1password-setup.sh

# ============================================================================
# Secret Loading Startup Script (OP_*_REF convention)
# ============================================================================
log_message "Creating 1Password secret loading startup script..."

# Create regular startup directory if it doesn't exist
log_command "Creating container startup directory" \
    mkdir -p /etc/container/startup

install -m 755 /tmp/build-scripts/features/lib/op-cli/45-op-secrets.sh \
    /etc/container/startup/45-op-secrets.sh

# ============================================================================
# Verification Script
# ============================================================================
log_message "Creating 1Password verification script..."

install -m 755 /tmp/build-scripts/features/lib/op-cli/test-1password.sh \
    /usr/local/bin/test-1password

# ============================================================================
# Installation Verification
# ============================================================================
log_message "Verifying 1Password CLI installation..."

# Verify installation
if command -v op &> /dev/null; then
    log_command "Checking 1Password CLI version" \
        op --version
else
    log_error "1Password CLI installation failed"
    log_feature_end
    exit 1
fi

# Log feature summary
# Export directory paths for feature summary (also defined in bashrc for runtime)
export OP_CACHE_DIR="/cache/1password"
export OP_CONFIG_DIR="/cache/1password/config"

log_feature_summary \
    --feature "1Password CLI" \
    --tools "op" \
    --paths "${OP_CACHE_DIR},${OP_CONFIG_DIR}" \
    --env "OP_CONFIG_DIR,OP_DATA_DIR" \
    --commands "op,op-signin-quick,op-get-secret,op-list-vaults,op-session-check" \
    --next-steps "Run 'test-1password' to verify installation. Authenticate with 'op signin' or use service accounts for automation. Use 'op inject' for secrets in configs."

# End logging
log_feature_end

echo ""
echo "Run 'test-1password' to verify installation"
echo "Run 'check-build-logs.sh 1password-cli' to review installation logs"
