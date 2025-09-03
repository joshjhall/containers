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
log_command "Adding 1Password GPG key" \
    curl -sS https://downloads.1password.com/linux/keys/1password.asc | \
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
log_command "Downloading 1Password debsig policy" \
    bash -c "curl -sS https://downloads.1password.com/linux/debian/debsig/1password.pol > /etc/debsig/policies/AC2D62742012EA22/1password.pol"
log_command "Creating debsig keyrings directory" \
    mkdir -p /usr/share/debsig/keyrings/AC2D62742012EA22
log_command "Adding 1Password debsig GPG key" \
    curl -sS https://downloads.1password.com/linux/keys/1password.asc | \
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
log_command "Creating 1Password cache directories" \
    mkdir -p "${OP_CACHE_DIR}" "${OP_CONFIG_DIR}"

# Set strict permissions on config directory (required by op CLI)
log_command "Setting config directory permissions" \
    chmod 700 "${OP_CONFIG_DIR}"

log_command "Setting cache directory ownership" \
    chown -R ${USER_UID}:${USER_GID} "${OP_CACHE_DIR}"

# ============================================================================
# System-wide Environment Configuration
# ============================================================================
log_message "Configuring system-wide 1Password environment..."

# Ensure /etc/bashrc.d exists
log_command "Creating bashrc.d directory" \
    mkdir -p /etc/bashrc.d

# Create system-wide 1Password configuration
write_bashrc_content /etc/bashrc.d/70-1password.sh "1Password CLI configuration" << 'ONEPASSWORD_BASHRC_EOF'
# ----------------------------------------------------------------------------
# 1Password CLI Configuration and Helpers
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

# Cache and config directories
export OP_CACHE_DIR="/cache/1password"
export OP_CONFIG_DIR="/cache/1password/config"

# Biometric unlock (when available)
export OP_BIOMETRIC_UNLOCK_ENABLED=true

# ----------------------------------------------------------------------------
# 1Password Aliases
# ----------------------------------------------------------------------------
# Common shortcuts
alias ops='op signin'
alias opl='op vault list'
alias opg='op item get'
alias opi='op inject'

# ----------------------------------------------------------------------------
# op-env - Load environment variables from 1Password
#
# Usage:
#   eval $(op-env <vault>/<item>)
#
# Example:
#   eval $(op-env Development/API-Keys)
# ----------------------------------------------------------------------------
op-env() {
    if [ -z "$1" ]; then
        echo "Usage: op-env <vault>/<item>" >&2
        return 1
    fi

    op item get "$1" --format json | jq -r '.fields[] | select(.purpose == "NOTES" or .type == "CONCEALED") | "export \(.label)=\"\(.value)\""'
}

# ----------------------------------------------------------------------------
# op-exec - Execute command with secrets from 1Password
#
# Usage:
#   op-exec <vault>/<item> <command> [args...]
#
# Example:
#   op-exec Development/API-Keys npm run deploy
# ----------------------------------------------------------------------------
op-exec() {
    if [ -z "$1" ] || [ -z "$2" ]; then
        echo "Usage: op-exec <vault>/<item> <command> [args...]" >&2
        return 1
    fi

    local item="$1"
    shift

    eval $(op-env "$item")
    "$@"
}

# Clean up helper functions
unset -f _check_command 2>/dev/null || true

# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
ONEPASSWORD_BASHRC_EOF

log_command "Setting 1Password bashrc script permissions" \
    chmod +x /etc/bashrc.d/70-1password.sh

# ============================================================================
# Container Startup Scripts
# ============================================================================
log_message "Creating 1Password startup script..."

# Create startup directory if it doesn't exist
log_command "Creating container startup directory" \
    mkdir -p /etc/container/first-startup

cat > /etc/container/first-startup/50-1password-setup.sh << 'EOF'
#!/bin/bash
# 1Password CLI setup

if command -v op &> /dev/null; then
    echo "=== 1Password CLI ==="
    echo "Version: $(op --version)"
    echo ""
    echo "To get started:"
    echo "  1. Sign in: op signin"
    echo "  2. List vaults: op vault list"
    echo "  3. Get item: op item get <item-name>"
    echo ""
    echo "Shortcuts available: ops, opl, opg, opi"
    echo "Load env vars: eval \$(op-env Vault/Item)"
fi
EOF

log_command "Setting 1Password startup script permissions" \
    chmod +x /etc/container/first-startup/50-1password-setup.sh

# ============================================================================
# Verification Script
# ============================================================================
log_message "Creating 1Password verification script..."

cat > /usr/local/bin/test-1password << 'EOF'
#!/bin/bash
echo "=== 1Password CLI Status ==="

if command -v op &> /dev/null; then
    echo "✓ 1Password CLI is installed"
    echo "  Version: $(op --version)"
    echo "  Binary: $(which op)"
else
    echo "✗ 1Password CLI is not installed"
    exit 1
fi

echo ""
echo "=== Configuration ==="
echo "  OP_CACHE_DIR: ${OP_CACHE_DIR:-/cache/1password}"
echo "  OP_CONFIG_DIR: ${OP_CONFIG_DIR:-/cache/1password/config}"

if [ -d "${OP_CACHE_DIR:-/cache/1password}" ]; then
    echo "  ✓ Cache directory exists"
else
    echo "  ✗ Cache directory missing"
fi

echo ""
echo "=== Authentication Status ==="
if op account list &>/dev/null 2>&1; then
    echo "✓ Authenticated to 1Password"
    op account list
else
    echo "✗ Not authenticated. Run 'op signin' to authenticate"
fi

echo ""
echo "Try these commands:"
echo "  op signin          - Authenticate to 1Password"
echo "  op vault list      - List available vaults"
echo "  op item list       - List items"
echo "  op inject -i file  - Inject secrets into file"
EOF

log_command "Setting test-1password script permissions" \
    chmod +x /usr/local/bin/test-1password

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

# End logging
log_feature_end

echo ""
echo "Run 'test-1password' to verify installation"
echo "Run 'check-build-logs.sh 1password-cli' to review installation logs"
