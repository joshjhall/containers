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
# ⚠️  SECURITY WARNING:
#   This function uses eval which can expose secrets in:
#   - Command history (if histappend is enabled)
#   - Process listings (ps aux shows full command)
#   - Debug logs (if set -x is enabled)
#
#   Consider using op-env-safe() instead for better security.
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
# op-env-safe - Load environment variables from 1Password (RECOMMENDED)
#
# Safer alternative to op-env that exports variables directly without eval.
# Prevents credential exposure in command history and process listings.
#
# Usage:
#   op-env-safe <vault>/<item>
#
# Example:
#   op-env-safe Development/API-Keys
#   echo \$API_KEY  # Variable is now available
# ----------------------------------------------------------------------------
op-env-safe() {
    # Disable command echoing to prevent exposure in logs
    local old_x_state=$(set +o | grep xtrace)
    set +x

    if [ -z "$1" ]; then
        echo "Usage: op-env-safe <vault>/<item>" >&2
        eval "$old_x_state"
        return 1
    fi

    local item="$1"
    local json_output

    # Fetch secrets from 1Password
    if ! json_output=$(op item get "$item" --format json 2>/dev/null); then
        echo "Failed to fetch secrets from 1Password: $item" >&2
        eval "$old_x_state"
        return 1
    fi

    # Parse and export variables without showing values in process list
    local export_commands
    export_commands=$(echo "$json_output" | jq -r '.fields[] | select(.purpose == "NOTES" or .type == "CONCEALED") | "export \(.label)=\"\(.value)\""' 2>/dev/null)

    if [ -z "$export_commands" ]; then
        echo "No environment variables found in 1Password item: $item" >&2
        eval "$old_x_state"
        return 1
    fi

    # Export variables using eval (unavoidable, but local to this function)
    eval "$export_commands"

    # Re-enable command echoing if it was on
    eval "$old_x_state"
}

# ----------------------------------------------------------------------------
# op-exec - Execute command with secrets from 1Password
#
# Uses op-env-safe internally to avoid credential exposure.
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

    # Use op-env-safe to load secrets securely
    op-env-safe "$item" || return 1
    "$@"
}

# ----------------------------------------------------------------------------
# Automatic Secret Loading from 1Password (OP_*_REF convention)
# ----------------------------------------------------------------------------
# Scans the environment for variables matching OP_<NAME>_REF and populates
# <NAME> from 1Password. Requires OP_SERVICE_ACCOUNT_TOKEN to be set.
#
# Convention:
#   OP_<NAME>_REF=op://vault/item/field  →  exports <NAME>=<secret_value>
#
# Examples:
#   OP_GITHUB_TOKEN_REF=op://Dev/GitHub-PAT/token   → GITHUB_TOKEN
#   OP_KAGI_API_KEY_REF=op://Dev/Kagi/api-key       → KAGI_API_KEY
#   OP_MY_SECRET_REF=op://Vault/Item/field           → MY_SECRET
#
# - Direct env var always wins (if <NAME> is already set, OP ref is skipped)
# - Fails silently if OP is unavailable or unauthenticated
# ----------------------------------------------------------------------------
_op_load_secrets() {
    # Skip if op not available or no service account token
    if ! _check_command op || [ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
        return 0
    fi

    # Disable xtrace to prevent token exposure in logs
    local _old_xtrace
    _old_xtrace=$(set +o | grep xtrace)
    set +x

    local _ref_var _target_var _ref_value _secret_value
    for _ref_var in $(compgen -v | grep '^OP_.\+_REF$'); do
        _target_var="${_ref_var#OP_}"
        _target_var="${_target_var%_REF}"
        [ -z "$_target_var" ] && continue
        # Skip if target variable is already set
        [ -n "${!_target_var:-}" ] && continue
        _ref_value="${!_ref_var:-}"
        [ -z "$_ref_value" ] && continue
        if _secret_value=$(op read "$_ref_value" 2>/dev/null); then
            export "${_target_var}=${_secret_value}"
        fi
    done

    # Restore xtrace state
    eval "$_old_xtrace"
}

# Automatically load secrets on shell initialization
_op_load_secrets

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

command cat > /etc/container/first-startup/50-1password-setup.sh << 'EOF'
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
# Secret Loading Startup Script (OP_*_REF convention)
# ============================================================================
log_message "Creating 1Password secret loading startup script..."

# Create regular startup directory if it doesn't exist
log_command "Creating container startup directory" \
    mkdir -p /etc/container/startup

command cat > /etc/container/startup/45-op-secrets.sh << 'EOF'
#!/bin/bash
# Load secrets from 1Password on container startup (OP_*_REF convention)
#
# This script runs on every container startup (not just first startup) to ensure
# secrets are available for background processes and non-interactive shells.
#
# Convention:
#   OP_<NAME>_REF=op://vault/item/field  →  exports <NAME>=<secret_value>
#
# Environment Variables:
#   OP_SERVICE_ACCOUNT_TOKEN - 1Password service account token (required)
#   OP_<NAME>_REF            - 1Password ref for any secret
#
# Examples:
#   OP_GITHUB_TOKEN_REF=op://Dev/GitHub-PAT/token   → GITHUB_TOKEN
#   OP_KAGI_API_KEY_REF=op://Dev/Kagi/api-key       → KAGI_API_KEY
#
set +e  # Don't exit on errors

# Skip if op not available
command -v op >/dev/null 2>&1 || exit 0

# Skip if no service account token configured
[ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ] && exit 0

# Disable xtrace to prevent secret exposure in logs
_old_xtrace=$(set +o | grep xtrace)
set +x

for _ref_var in $(compgen -v | grep '^OP_.\+_REF$'); do
    _target_var="${_ref_var#OP_}"
    _target_var="${_target_var%_REF}"
    [ -z "$_target_var" ] && continue
    # Skip if target variable is already set
    [ -n "${!_target_var:-}" ] && continue
    _ref_value="${!_ref_var:-}"
    [ -z "$_ref_value" ] && continue
    if _secret_value=$(op read "$_ref_value" 2>/dev/null); then
        export "${_target_var}=${_secret_value}"
    fi
done

# Restore xtrace state
eval "$_old_xtrace"

exit 0
EOF

log_command "Setting 1Password secret startup script permissions" \
    chmod 755 /etc/container/startup/45-op-secrets.sh

# ============================================================================
# Verification Script
# ============================================================================
log_message "Creating 1Password verification script..."

command cat > /usr/local/bin/test-1password << 'EOF'
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
