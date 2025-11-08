#!/bin/bash
# Cloudflare Developer Tools - Wrangler CLI and Cloudflare Tunnel
#
# Description:
#   Installs official Cloudflare development tools for Workers, Pages, and Tunnels.
#   Includes helper functions and aliases for common Cloudflare operations.
#
# Features:
#   - Wrangler CLI: Deploy and manage Cloudflare Workers and Pages
#   - Cloudflared: Create secure tunnels to localhost services
#   - Helper functions for quick tunnel creation and worker testing
#   - Auto-completion and authentication management
#   - Workspace configuration detection and linking
#
# Tools Installed:
#   - wrangler: Latest version via npm (Workers/Pages CLI)
#   - cloudflared: Latest version via GitHub releases (Tunnel client)
#
# Environment Variables:
#   - CLOUDFLARE_ACCOUNT_ID: Your Cloudflare account ID (optional)
#   - CLOUDFLARE_API_TOKEN: API token for authentication (optional)
#
# Note:
#   Requires Node.js to be installed for wrangler.
#   Authentication credentials are automatically linked from the working directory if present.
#
set -euo pipefail

# Source standard feature header for user handling
source /tmp/build-scripts/base/feature-header.sh

# Source apt utilities for reliable package installation
source /tmp/build-scripts/base/apt-utils.sh

# Start logging
log_feature_start "Cloudflare Tools"

# ============================================================================
# Dependencies
# ============================================================================
log_message "Checking dependencies..."

# Wrangler requires Node.js 20 specifically (not 22 or other versions)
CLOUDFLARE_NODE_VERSION="${CLOUDFLARE_NODE_VERSION:-20}"

# Check if Node.js is already installed and meets version requirements
NODE_INSTALLED=false
NODE_VERSION_OK=false

if command -v node &> /dev/null; then
    NODE_INSTALLED=true
    NODE_VERSION=$(node --version | grep -oE '[0-9]+' | head -1)
    log_message "Node.js already installed: $(node --version)"

    # Check if Node.js version meets Cloudflare requirements
    if [ "$NODE_VERSION" -ge "$CLOUDFLARE_NODE_VERSION" ]; then
        NODE_VERSION_OK=true
    else
        log_warning "Wrangler requires Node.js ${CLOUDFLARE_NODE_VERSION} or higher. Current version: $(node --version)"
    fi
fi

# Install Node.js if not installed or version is too old
if [ "$NODE_INSTALLED" = false ] || [ "$NODE_VERSION_OK" = false ]; then
    log_message "Installing Node.js ${CLOUDFLARE_NODE_VERSION} LTS for wrangler compatibility..."

    # Install prerequisites for NodeSource repository
    log_message "Installing prerequisites"
    apt_update
    apt_install ca-certificates curl gnupg

    # ========================================================================
    # Add NodeSource Repository (Manual Setup - Secure Method)
    # ========================================================================
    # Instead of using NodeSource's setup script (which executes remote code),
    # we manually add the repository. This is more transparent and secure.
    log_message "Adding NodeSource repository manually..."

    # Download and install NodeSource GPG key
    log_command "Downloading NodeSource GPG key" \
        curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key -o /tmp/nodesource.gpg.key

    # Convert GPG key to binary format for apt (required for Debian 13+)
    log_command "Converting GPG key to binary format" \
        gpg --dearmor -o /usr/share/keyrings/nodesource.gpg < /tmp/nodesource.gpg.key

    # Add NodeSource repository with signed-by directive
    log_message "Adding NodeSource repository to apt sources..."
    cat > /etc/apt/sources.list.d/nodesource.list << EOF
deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${CLOUDFLARE_NODE_VERSION}.x nodistro main
EOF

    # Clean up temporary GPG key file
    rm -f /tmp/nodesource.gpg.key

    # Update apt package lists
    apt_update

    # Install Node.js
    log_message "Installing Node.js ${CLOUDFLARE_NODE_VERSION}"
    apt_install nodejs

    # Verify installation
    if command -v node &> /dev/null; then
        log_message "Node.js installed successfully: $(node --version)"
    else
        log_error "Failed to install Node.js"
        log_feature_end
        exit 1
    fi
fi

# Check if npm is available
if ! command -v npm &> /dev/null; then
    log_warning "npm not found. Node.js installation may be incomplete."
    exit 1
fi

# ============================================================================
# Wrangler Installation
# ============================================================================
log_message "Checking for wrangler (Cloudflare Workers CLI)..."

# ALWAYS use /cache paths for consistency
# These will either use cache mounts (faster rebuilds) or be created in the image
NPM_CACHE_DIR="/cache/npm"
NPM_PREFIX="/cache/npm-global"
log_message "NPM cache: ${NPM_CACHE_DIR}"
log_message "NPM global prefix: ${NPM_PREFIX}"

# Create npm directories with correct ownership
# This ensures they exist in the image even without cache mounts
log_command "Creating npm directories" \
    mkdir -p "$NPM_CACHE_DIR" "$NPM_PREFIX"

log_command "Setting npm directory ownership" \
    chown -R ${USER_UID}:${USER_GID} "$NPM_CACHE_DIR" "$NPM_PREFIX"

# Also add to system-wide PATH before checking
export PATH="${NPM_PREFIX}/bin:$PATH"

# Check if wrangler is already installed
if command -v wrangler &> /dev/null; then
    log_message "✓ wrangler is already installed at $(which wrangler)"
    log_message "  Version: $(wrangler --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo 'unknown')"
else
    log_message "wrangler not found - installing wrangler globally..."

    # Install wrangler globally as the user
    log_command "Installing wrangler globally" \
        su - ${USERNAME} -c "
            export npm_config_cache='${NPM_CACHE_DIR}'
            export npm_config_prefix='${NPM_PREFIX}'
            export PATH='${NPM_PREFIX}/bin:\$PATH'

            # Ensure npm is in PATH (from Node.js installation)
            export PATH='/usr/bin:\$PATH'

            npm install -g wrangler

            # Add npm global bin to PATH if not already there
            if ! grep -q \"${NPM_PREFIX}/bin\" ~/.bashrc; then
                echo 'export PATH=\"${NPM_PREFIX}/bin:\$PATH\"' >> ~/.bashrc
            fi
        "
fi

# Also add to system-wide PATH
log_command "Adding npm global to system PATH" \
    bash -c "echo 'export PATH=\"${NPM_PREFIX}/bin:\$PATH\"' > /etc/profile.d/npm-global.sh"

log_command "Setting npm profile script permissions" \
    chmod +x /etc/profile.d/npm-global.sh

# ============================================================================
# Cloudflared Installation
# ============================================================================
log_message "Installing cloudflared (Cloudflare Tunnel)..."

# Detect architecture for correct binary
ARCH=$(dpkg --print-architecture)
if [ "$ARCH" = "amd64" ]; then
    log_command "Downloading cloudflared for amd64" \
        curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o /tmp/cloudflared.deb
elif [ "$ARCH" = "arm64" ]; then
    log_command "Downloading cloudflared for arm64" \
        curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb -o /tmp/cloudflared.deb
else
    log_warning "cloudflared not available for architecture $ARCH, skipping..."
fi

if [ -f /tmp/cloudflared.deb ]; then
    log_command "Installing cloudflared package" \
        dpkg -i /tmp/cloudflared.deb

    log_command "Cleaning up cloudflared installer" \
        rm -f /tmp/cloudflared.deb
fi

# ============================================================================
# Environment Configuration
# ============================================================================
log_message "Configuring Cloudflare environment..."

# Ensure /etc/bashrc.d exists
log_command "Creating bashrc.d directory" \
    mkdir -p /etc/bashrc.d

# Create system-wide Cloudflare configuration
write_bashrc_content /etc/bashrc.d/65-cloudflare.sh "Cloudflare tools configuration" << 'CLOUDFLARE_BASHRC_EOF'
# ----------------------------------------------------------------------------
# Cloudflare Tools Configuration and Helpers
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
# Wrangler Aliases - Cloudflare Workers CLI shortcuts
# ----------------------------------------------------------------------------
alias wr='wrangler'
alias wrd='wrangler dev'
alias wrp='wrangler publish'         # Deprecated, use deploy
alias wrdeploy='wrangler deploy'
alias wrlogs='wrangler tail'
alias wrlogin='wrangler login'
alias wrwhoami='wrangler whoami'

# ----------------------------------------------------------------------------
# Cloudflared Aliases - Tunnel management shortcuts
# ----------------------------------------------------------------------------
alias cft='cloudflared tunnel'
alias cftlist='cloudflared tunnel list'
alias cftrun='cloudflared tunnel run'
alias cftcreate='cloudflared tunnel create'
alias cftdelete='cloudflared tunnel delete'
alias cftroute='cloudflared tunnel route'

# ----------------------------------------------------------------------------
# wrangler-init - Initialize a new Workers project
#
# Arguments:
#   $1 - Project name (default: my-worker)
#   $2 - Template name (optional)
#
# Examples:
#   wrangler-init my-api
#   wrangler-init my-site "https://github.com/cloudflare/worker-template"
# ----------------------------------------------------------------------------
wrangler-init() {
    local project_name="${1:-my-worker}"
    local template="${2:-}"

    if [ -n "$template" ]; then
        wrangler init "$project_name" --template "$template"
    else
        wrangler init "$project_name"
    fi
    cd "$project_name"
}

# ----------------------------------------------------------------------------
# wrangler-deploy - Deploy current project to Cloudflare Workers
#
# Requires:
#   wrangler.toml in current directory
# ----------------------------------------------------------------------------
wrangler-deploy() {
    if [ ! -f wrangler.toml ]; then
        echo "Error: No wrangler.toml found in current directory"
        return 1
    fi
    wrangler deploy
}

# ----------------------------------------------------------------------------
# tunnel-quick - Start a quick public tunnel to localhost
#
# Arguments:
#   $1 - Port number (default: 8080)
#
# Example:
#   tunnel-quick 3000  # Expose localhost:3000 to the internet
# ----------------------------------------------------------------------------
tunnel-quick() {
    local port="${1:-8080}"
    echo "Starting Cloudflare tunnel on port $port..."
    cloudflared tunnel --url "http://localhost:$port"
}

tunnel-create() {
    if [ -z "$1" ]; then
        echo "Usage: tunnel-create <tunnel-name>"
        return 1
    fi
    cloudflared tunnel create "$1"
    echo "Don't forget to create a config file and route DNS!"
}

# Helper to test Workers locally
worker-test() {
    if [ ! -f wrangler.toml ]; then
        echo "Error: No wrangler.toml found in current directory"
        return 1
    fi
    echo "Starting local development server..."
    wrangler dev --local
}

# Auto-completion for wrangler (removed - wrangler doesn't support completions command)

# Clean up helper functions
unset -f _check_command 2>/dev/null || true

# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
CLOUDFLARE_BASHRC_EOF

log_command "Setting Cloudflare bashrc script permissions" \
    chmod +x /etc/bashrc.d/65-cloudflare.sh

# ============================================================================
# Container Startup Scripts
# ============================================================================
log_message "Creating Cloudflare startup scripts..."

# Create startup directory if it doesn't exist
log_command "Creating container startup directory" \
    mkdir -p /etc/container/first-startup

cat > /etc/container/first-startup/20-cloudflare-setup.sh << EOF
#!/bin/bash
# Check for Cloudflare credentials
if [ ! -f ~/.wrangler/config/default.toml ] && [ -f ${WORKING_DIR}/.wrangler/config/default.toml ]; then
    echo "=== Cloudflare Configuration ==="
    echo "Linking workspace wrangler configuration..."
    mkdir -p ~/.wrangler/config
    ln -s ${WORKING_DIR}/.wrangler/config/default.toml ~/.wrangler/config/default.toml
fi

# Check for cloudflared credentials
if [ ! -d ~/.cloudflared ] && [ -d ${WORKING_DIR}/.cloudflared ]; then
    echo "Linking workspace cloudflared configuration..."
    ln -s ${WORKING_DIR}/.cloudflared ~/.cloudflared
fi

# Check if wrangler is configured
if command -v wrangler &> /dev/null; then
    if wrangler whoami &> /dev/null 2>&1; then
        echo "Wrangler is authenticated"
        wrangler whoami 2>/dev/null
    else
        echo "Wrangler is installed but not authenticated"
        echo "Run 'wrangler login' to authenticate"
    fi
fi

# Check for Workers project
if [ -f ${WORKING_DIR}/wrangler.toml ]; then
    echo "Cloudflare Workers project detected"
fi
EOF

log_command "Setting Cloudflare startup script permissions" \
    chmod +x /etc/container/first-startup/20-cloudflare-setup.sh

# ============================================================================
# Verification Script
# ============================================================================
log_message "Creating Cloudflare verification script..."

cat > /usr/local/bin/test-cloudflare << 'EOF'
#!/bin/bash
echo "=== Cloudflare Tools Status ==="

echo ""
echo "Wrangler (Workers CLI):"
if command -v wrangler &> /dev/null; then
    echo "✓ wrangler is installed"
    echo "  Version: $(wrangler --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    echo "  Binary: $(which wrangler)"
else
    echo "✗ wrangler is not installed"
fi

echo ""
echo "Cloudflared (Tunnel):"
if command -v cloudflared &> /dev/null; then
    echo "✓ cloudflared is installed"
    echo "  Version: $(cloudflared --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    echo "  Binary: $(which cloudflared)"
else
    echo "✗ cloudflared is not installed"
fi

echo ""
echo "=== Configuration ==="
echo "  NPM cache: /cache/npm"
echo "  NPM global: /cache/npm-global"

if [ -d ~/.wrangler/config ]; then
    echo "  ✓ Wrangler config directory exists"
else
    echo "  ✗ Wrangler config directory not found"
fi

if [ -d ~/.cloudflared ]; then
    echo "  ✓ Cloudflared config directory exists"
else
    echo "  ✗ Cloudflared config directory not found"
fi

echo ""
echo "=== Authentication Status ==="
if command -v wrangler &> /dev/null; then
    if wrangler whoami &>/dev/null 2>&1; then
        echo "✓ Wrangler is authenticated"
        wrangler whoami 2>/dev/null || true
    else
        echo "✗ Wrangler is not authenticated"
        echo "  Run 'wrangler login' to authenticate"
    fi
fi

# Check for Workers project
# Check current directory first, then working directory
if [ -f wrangler.toml ]; then
    echo ""
    echo "✓ Cloudflare Workers project detected (current directory)"
elif [ -f ${WORKING_DIR}/wrangler.toml ]; then
    echo ""
    echo "✓ Cloudflare Workers project detected in working directory"
    echo "  Found: ${WORKING_DIR}/wrangler.toml"
fi
EOF

log_command "Setting test-cloudflare permissions" \
    chmod +x /usr/local/bin/test-cloudflare

# ============================================================================
# Final Verification
# ============================================================================
log_message "Verifying Cloudflare tools installation..."

# Need to export PATH for verification
export PATH="${NPM_PREFIX}/bin:$PATH"

if command -v wrangler &> /dev/null; then
    log_command "Checking wrangler version" \
        wrangler --version || log_warning "wrangler version check failed"
fi

if command -v cloudflared &> /dev/null; then
    log_command "Checking cloudflared version" \
        cloudflared --version || log_warning "cloudflared version check failed"
fi

# End logging
log_feature_end

echo ""
echo "Run 'test-cloudflare' to verify installation"
echo "Run 'check-build-logs.sh cloudflare' to review installation logs"
