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
#   OP_<NAME>_REF=op://vault/item/field       →  exports <NAME>=<secret_value>
#   OP_<NAME>_FILE_REF=op://vault/item/file   →  writes to /dev/shm, exports <NAME>=<path>
#
# Environment Variables:
#   OP_SERVICE_ACCOUNT_TOKEN  - 1Password service account token (required)
#   OP_<NAME>_REF             - 1Password ref for any string secret
#   OP_<NAME>_FILE_REF        - 1Password ref for file secrets (written to /dev/shm)
#
# Examples:
#   OP_GITHUB_TOKEN_REF=op://Dev/GitHub-PAT/token   → GITHUB_TOKEN
#   OP_KAGI_API_KEY_REF=op://Dev/Kagi/api-key       → KAGI_API_KEY
#   OP_GOOGLE_APPLICATION_CREDENTIALS_FILE_REF=op://Dev/GCP/sa-key.json
#       → writes to /dev/shm/google-application-credentials.json
#       → GOOGLE_APPLICATION_CREDENTIALS=/dev/shm/google-application-credentials.json
#
set +e  # Don't exit on errors

# Skip if op not available
command -v op >/dev/null 2>&1 || exit 0

# Skip if no service account token configured
[ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ] && exit 0

# Disable xtrace to prevent secret exposure in logs
_old_xtrace=$(set +o | grep xtrace)
set +x

for _ref_var in $(compgen -v | grep '^OP_.\+_REF$' | grep -v '_FILE_REF$'); do
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

# FILE_REF loop: fetch content, write to /dev/shm, export file path
for _ref_var in $(compgen -v | grep '^OP_.\+_FILE_REF$'); do
    _target_var="${_ref_var#OP_}"
    _target_var="${_target_var%_FILE_REF}"
    [ -z "$_target_var" ] && continue
    # Skip if target variable is already set
    [ -n "${!_target_var:-}" ] && continue
    _ref_value="${!_ref_var:-}"
    [ -z "$_ref_value" ] && continue
    if _secret_value=$(op read "$_ref_value" 2>/dev/null); then
        # Derive filename: lowercase target var with dashes
        _file_name=$(echo "$_target_var" | tr '[:upper:]_' '[:lower:]-')
        # Derive extension from the URI's last path segment
        _uri_field="${_ref_value##*/}"
        case "$_uri_field" in
            *.*) _file_ext=".${_uri_field##*.}" ;;
            *)   _file_ext="" ;;
        esac
        _file_path="/dev/shm/${_file_name}${_file_ext}"
        printf '%s' "$_secret_value" > "$_file_path"
        chmod 600 "$_file_path"
        export "${_target_var}=${_file_path}"
    fi
done

# Smart Git Identity Resolution: if GIT_USER_NAME wasn't resolved (e.g.,
# Identity item with separate first/last fields), try combining them.
if [ -z "${GIT_USER_NAME:-}" ] && [ -n "${OP_GIT_USER_NAME_REF:-}" ]; then
    _base_path="${OP_GIT_USER_NAME_REF%/*}"
    _first=$(op read "${_base_path}/first name" 2>/dev/null) || true
    _last=$(op read "${_base_path}/last name" 2>/dev/null) || true
    if [ -n "${_first}" ] || [ -n "${_last}" ]; then
        export GIT_USER_NAME="${_first}${_first:+ }${_last}"
    fi
fi

# Apply defaults so git operations never fail
[ -z "${GIT_USER_NAME:-}" ] && export GIT_USER_NAME="Devcontainer"
[ -z "${GIT_USER_EMAIL:-}" ] && export GIT_USER_EMAIL="devcontainer@localhost"

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
