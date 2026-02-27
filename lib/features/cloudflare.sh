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
#   Wrangler requires Node.js. If Node.js is not installed or version is below 20,
#   this feature will automatically install Node.js 20 LTS.
#   Authentication credentials are automatically linked from the working directory if present.
#
set -euo pipefail

# Source standard feature header for user handling
source /tmp/build-scripts/base/feature-header.sh

# Source download verification utilities for secure binary downloads
source /tmp/build-scripts/base/download-verify.sh

# Source checksum utilities for secure binary downloads
source /tmp/build-scripts/base/checksum-fetch.sh
source /tmp/build-scripts/base/cache-utils.sh

# Source apt utilities for reliable package installation
source /tmp/build-scripts/base/apt-utils.sh

# Source retry utilities for network operations
source /tmp/build-scripts/base/retry-utils.sh

# Source path utilities for secure PATH management
source /tmp/build-scripts/base/path-utils.sh

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
    log_message "Downloading NodeSource GPG key"
    retry_with_backoff curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key -o /tmp/nodesource.gpg.key

    # Convert GPG key to binary format for apt (required for Debian 13+)
    log_command "Converting GPG key to binary format" \
        gpg --dearmor -o /usr/share/keyrings/nodesource.gpg < /tmp/nodesource.gpg.key

    # Add NodeSource repository with signed-by directive
    log_message "Adding NodeSource repository to apt sources..."
    command cat > /etc/apt/sources.list.d/nodesource.list << EOF
deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${CLOUDFLARE_NODE_VERSION}.x nodistro main
EOF

    # Clean up temporary GPG key file
    command rm -f /tmp/nodesource.gpg.key

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
create_cache_directories "$NPM_CACHE_DIR" "$NPM_PREFIX"
create_cache_directories "$NPM_CACHE_DIR" "$NPM_PREFIX"
    bash -c "install -d -m 0755 -o '${USER_UID}' -g '${USER_GID}' '$NPM_CACHE_DIR' && install -d -m 0755 -o '${USER_UID}' -g '${USER_GID}' '$NPM_PREFIX'"

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
        su - "${USERNAME}" -c "
            # Source path utilities for secure PATH management
            if [ -f /tmp/build-scripts/base/path-utils.sh ]; then
                source /tmp/build-scripts/base/path-utils.sh
            fi

            export npm_config_cache='${NPM_CACHE_DIR}'
            export npm_config_prefix='${NPM_PREFIX}'

            # Securely add to PATH
            if command -v safe_add_to_path >/dev/null 2>&1; then
                safe_add_to_path '${NPM_PREFIX}/bin' 2>/dev/null || export PATH='${NPM_PREFIX}/bin:\$PATH'
                safe_add_to_path '/usr/bin' 2>/dev/null || export PATH='/usr/bin:\$PATH'
            else
                export PATH='${NPM_PREFIX}/bin:\$PATH'
                export PATH='/usr/bin:\$PATH'
            fi

            npm install -g wrangler

            # Add npm global bin to PATH if not already there
            if ! grep -q \"${NPM_PREFIX}/bin\" ~/.bashrc; then
                echo 'export PATH=\"${NPM_PREFIX}/bin:\$PATH\"' >> ~/.bashrc
            fi
        "
fi

# Also add to system-wide PATH
log_message "Adding npm global to system PATH..."
export PATH="${NPM_PREFIX}/bin:$PATH"

# ============================================================================
# Cloudflared Installation
# ============================================================================
log_message "Installing cloudflared (Cloudflare Tunnel)..."

# Detect architecture for correct binary
ARCH=$(dpkg --print-architecture)
CLOUDFLARED_VERSION="2025.11.1"  # Can be overridden with CLOUDFLARED_VERSION build arg

if [ "$ARCH" = "amd64" ]; then
    CLOUDFLARED_DEB="cloudflared-linux-amd64.deb"
elif [ "$ARCH" = "arm64" ]; then
    CLOUDFLARED_DEB="cloudflared-linux-arm64.deb"
else
    log_warning "cloudflared not available for architecture $ARCH, skipping..."
    CLOUDFLARED_DEB=""
fi

if [ -n "$CLOUDFLARED_DEB" ]; then
    CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/${CLOUDFLARED_DEB}"

    # Calculate checksum from download (cloudflared doesn't publish checksums)
    log_message "Calculating checksum for cloudflared ${CLOUDFLARED_VERSION}..."
    if ! CLOUDFLARED_CHECKSUM=$(calculate_checksum_sha256 "$CLOUDFLARED_URL" 2>/dev/null); then
        log_error "Failed to download and calculate checksum for cloudflared ${CLOUDFLARED_VERSION}"
        log_error "Please verify version exists: https://github.com/cloudflare/cloudflared/releases/tag/${CLOUDFLARED_VERSION}"
        log_feature_end
        exit 1
    fi

    log_message "✓ Calculated checksum from download"

    # Download and verify cloudflared
    BUILD_TEMP=$(create_secure_temp_dir)
    cd "$BUILD_TEMP"
    log_message "Downloading and verifying cloudflared for ${ARCH}..."
    download_and_verify \
        "$CLOUDFLARED_URL" \
        "${CLOUDFLARED_CHECKSUM}" \
        "cloudflared.deb"

    log_command "Installing cloudflared package" \
        dpkg -i cloudflared.deb

    cd /
    log_command "Cleaning up build directory" \
        command rm -rf "$BUILD_TEMP"
fi

# ============================================================================
# Environment Configuration
# ============================================================================
log_message "Configuring Cloudflare environment..."

# Ensure /etc/bashrc.d exists
log_command "Creating bashrc.d directory" \
    mkdir -p /etc/bashrc.d

# Create system-wide Cloudflare configuration (content in lib/bashrc/cloudflare.sh)
write_bashrc_content /etc/bashrc.d/65-cloudflare.sh "Cloudflare tools configuration" \
    < /tmp/build-scripts/features/lib/bashrc/cloudflare.sh

log_command "Setting Cloudflare bashrc script permissions" \
    chmod +x /etc/bashrc.d/65-cloudflare.sh

# ============================================================================
# Container Startup Scripts
# ============================================================================
log_message "Creating Cloudflare startup scripts..."

# Create startup directory if it doesn't exist
log_command "Creating container startup directory" \
    mkdir -p /etc/container/first-startup

command cat > /etc/container/first-startup/20-cloudflare-setup.sh << EOF
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

command cat > /usr/local/bin/test-cloudflare << 'EOF'
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

# Log feature summary
# Set NPM_GLOBAL_DIR for paths (also set in node.sh if Node is installed)
export NPM_GLOBAL_DIR="${NPM_GLOBAL_DIR:-/cache/npm-global}"

log_feature_summary \
    --feature "Cloudflare Tools" \
    --tools "wrangler,cloudflared" \
    --paths "${NPM_GLOBAL_DIR},$HOME/.wrangler,$HOME/.cloudflared" \
    --env "CLOUDFLARE_ACCOUNT_ID,CLOUDFLARE_API_TOKEN,NPM_CACHE_DIR,NPM_PREFIX" \
    --commands "wrangler,cloudflared,wr,wrd,wrdeploy,cft,tunnel-quick,wrangler-init" \
    --next-steps "Run 'test-cloudflare' to verify installation. Authenticate with 'wrangler login'."

# End logging
log_feature_end

echo ""
echo "Run 'test-cloudflare' to verify installation"
echo "Run 'check-build-logs.sh cloudflare' to review installation logs"
