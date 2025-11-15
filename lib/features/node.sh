#!/bin/bash
# Node.js - JavaScript runtime with npm, yarn, and pnpm
#
# Description:
#   Installs Node.js directly from source with modern package managers.
#   Configures cache directories for optimal container performance.
#
# Features:
#   - Node.js runtime from nodejs.org
#   - npm (included with Node.js)
#   - yarn and pnpm (via corepack)
#   - Automatic dependency detection and installation
#   - Cache optimization for containerized environments
#
# Environment Variables:
#   - NODE_VERSION: Version specification (default: 22)
#     * Major version only (e.g., "22"): Resolves to latest 22.x with pinned checksum
#     * Partial version (e.g., "22.12"): Resolves to latest 22.12.x with pinned checksum
#     * Specific version (e.g., "22.12.0"): Uses exact version
#
# Supported Versions:
#   - 22.x (current LTS)
#   - 20.x (previous LTS)
#   - 18.x (maintenance LTS)
#
set -euo pipefail

# Source standard feature header for user handling
source /tmp/build-scripts/base/feature-header.sh

# Source apt utilities for reliable package installation
source /tmp/build-scripts/base/apt-utils.sh

# Source download and verification utilities
source /tmp/build-scripts/base/download-verify.sh

# Source checksum verification utilities
source /tmp/build-scripts/features/lib/checksum-fetch.sh

# Source version validation utilities
source /tmp/build-scripts/base/version-validation.sh

# Source version resolution for partial version support
source /tmp/build-scripts/base/version-resolution.sh

# Source 4-tier checksum verification system
source /tmp/build-scripts/base/checksum-verification.sh
source /tmp/build-scripts/base/cache-utils.sh

# ============================================================================
# Version Configuration
# ============================================================================
NODE_VERSION="${NODE_VERSION:-22}"

# Validate Node.js version format to prevent shell injection
validate_node_version "$NODE_VERSION" || {
    log_error "Build failed due to invalid NODE_VERSION"
    exit 1
}

# Resolve partial versions to full versions (e.g., "22" -> "22.12.0")
# This enables users to use partial versions and get latest patches with pinned checksums
ORIGINAL_VERSION="$NODE_VERSION"
NODE_VERSION=$(resolve_node_version "$NODE_VERSION" 2>/dev/null || echo "$NODE_VERSION")

if [ "$ORIGINAL_VERSION" != "$NODE_VERSION" ]; then
    log_message "📍 Version Resolution: $ORIGINAL_VERSION → $NODE_VERSION"
    log_message "   Using latest patch version with pinned checksum verification"
fi

# Start logging
log_feature_start "Node.js" "${NODE_VERSION}"

# Extract major version for EOL check
NODE_MAJOR_VERSION=$(echo "${NODE_VERSION}" | cut -d. -f1)

# Ensure Node.js version is 18 or higher (16 EOL was April 2024)
if [ "$NODE_MAJOR_VERSION" -lt 18 ]; then
    log_error "Node.js version must be 18 or higher"
    log_error "Node.js 16 reached end-of-life in April 2024"
    log_error "Requested version: ${NODE_VERSION} (major: ${NODE_MAJOR_VERSION})"
    log_feature_end
    exit 1
fi

# ============================================================================
# System Dependencies
# ============================================================================
log_message "Installing Node.js build dependencies..."

# Update package lists with retry logic
apt_update

# Install Node.js dependencies with retry logic
apt_install \
    curl \
    ca-certificates \
    xz-utils

# ============================================================================
# Node.js Installation from Source
# ============================================================================
log_message "Downloading and installing Node.js ${NODE_VERSION}..."

# Determine architecture
ARCH=$(dpkg --print-architecture)
case "$ARCH" in
    amd64)
        NODE_ARCH="x64"
        ;;
    arm64)
        NODE_ARCH="arm64"
        ;;
    *)
        log_error "Unsupported architecture: $ARCH"
        log_error "Node.js only supports amd64 (x64) and arm64"
        exit 1
        ;;
esac

log_message "Detected architecture: ${ARCH} (Node.js: ${NODE_ARCH})"

BUILD_TEMP=$(create_secure_temp_dir)
cd "$BUILD_TEMP"

# Download Node.js tarball with 4-tier checksum verification
NODE_TARBALL="node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz"
NODE_URL="https://nodejs.org/dist/v${NODE_VERSION}/${NODE_TARBALL}"

# Download Node.js tarball
log_message "Downloading Node.js ${NODE_VERSION}..."
if ! curl -fsSL "$NODE_URL" -o "$NODE_TARBALL"; then
    log_error "Failed to download Node.js ${NODE_VERSION}"
    log_error "Please verify version exists: https://nodejs.org/dist/v${NODE_VERSION}/"
    log_feature_end
    exit 1
fi

# Verify using 4-tier system (GPG → Pinned → Published → Calculated)
# This will try each tier in order and log which method succeeded
if ! verify_download "language" "nodejs" "$NODE_VERSION" "$NODE_TARBALL" "$NODE_ARCH"; then
    log_error "Checksum verification failed for Node.js ${NODE_VERSION}"
    log_feature_end
    exit 1
fi

log_command "Extracting Node.js to /usr/local" \
    tar -xJf "$NODE_TARBALL" --strip-components=1 -C /usr/local

# Clean up build files
cd /
log_command "Cleaning up Node.js build directory" \
    rm -rf "$BUILD_TEMP"

# ============================================================================
# Package Manager Setup
# ============================================================================
log_message "Setting up package managers..."

# Enable corepack for yarn and pnpm
log_command "Enabling corepack" \
    corepack enable

# Install/activate specific versions of package managers via corepack
# This ensures consistency across environments
log_command "Preparing yarn" \
    corepack prepare yarn@stable --activate

# Pin pnpm to version 9.x to avoid signature verification issues with @latest
# If this fails, pnpm will still be available via corepack, just not pre-installed
if ! log_command "Preparing pnpm" corepack prepare pnpm@9 --activate; then
    log_warning "Failed to prepare pnpm@9, but pnpm is still available via corepack"
    log_warning "You can activate it later with: corepack enable && corepack use pnpm@9"
fi

# ============================================================================
# Cache and Path Configuration
# ============================================================================
log_message "Configuring Node.js cache and paths..."

# ALWAYS use /cache paths for consistency with other languages
# This will either use cache mount (faster rebuilds) or be created in the image
NPM_CACHE_DIR="/cache/npm"
YARN_CACHE_DIR="/cache/yarn"
PNPM_STORE_DIR="/cache/pnpm"
NPM_GLOBAL_DIR="/cache/npm-global"

# Create cache directories with correct ownership using shared utility
create_cache_directories "${NPM_CACHE_DIR}" "${YARN_CACHE_DIR}" "${PNPM_STORE_DIR}" "${NPM_GLOBAL_DIR}"

log_message "Node.js cache paths:"
log_message "  NPM cache: ${NPM_CACHE_DIR}"
log_message "  Yarn cache: ${YARN_CACHE_DIR}"
log_message "  pnpm store: ${PNPM_STORE_DIR}"
log_message "  NPM global: ${NPM_GLOBAL_DIR}"

# ============================================================================
# Verify Node.js binaries
# ============================================================================
log_message "Verifying Node.js installation..."

# Node.js is extracted directly to /usr/local/bin
NODE_BIN_DIR="/usr/local/bin"

# Verify core binaries exist
for cmd in node npm npx; do
    if [ ! -f "${NODE_BIN_DIR}/${cmd}" ]; then
        log_error "Missing ${cmd} binary after installation"
        exit 1
    fi
done

log_message "✓ Node.js binaries verified in /usr/local/bin"

# ============================================================================
# System-wide Environment Configuration
# ============================================================================
log_message "Configuring system-wide Node.js environment..."

# Ensure /etc/bashrc.d exists
log_command "Creating bashrc.d directory" \
    mkdir -p /etc/bashrc.d

# Create system-wide Node.js configuration
write_bashrc_content /etc/bashrc.d/30-node.sh "Node.js configuration" << 'NODE_BASHRC_EOF'
# ----------------------------------------------------------------------------
# Node.js environment configuration
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

# Export paths and environment variables
export NPM_CACHE_DIR="/cache/npm"
export YARN_CACHE_DIR="/cache/yarn"
export PNPM_STORE_DIR="/cache/pnpm"
export NPM_GLOBAL_DIR="/cache/npm-global"

# Add global package directories to PATH
export PATH="${NPM_GLOBAL_DIR}/bin:$PATH"

# Package manager cache environment variables
export npm_config_cache="${NPM_CACHE_DIR}"
export YARN_CACHE_FOLDER="${YARN_CACHE_DIR}"
export PNPM_STORE="${PNPM_STORE_DIR}"
export npm_config_prefix="${NPM_GLOBAL_DIR}"

NODE_BASHRC_EOF

log_command "Setting Node.js bashrc script permissions" \
    chmod +x /etc/bashrc.d/30-node.sh

# ============================================================================
# Shell Aliases and Functions
# ============================================================================
log_message "Setting up Node.js aliases and helpers..."

write_bashrc_content /etc/bashrc.d/30-node.sh "Node.js aliases" << 'NODE_BASHRC_EOF'

# ----------------------------------------------------------------------------
# Node.js Aliases
# ----------------------------------------------------------------------------
alias npm-clean='npm cache clean --force'
alias yarn-clean='yarn cache clean 2>/dev/null || echo "yarn cache clean skipped (corepack issue)"'
alias pnpm-clean='pnpm store prune 2>/dev/null || echo "pnpm store prune skipped (corepack issue)"'
# Use ; instead of && to continue even if yarn/pnpm fail
alias node-clean='npm-clean ; yarn-clean ; pnpm-clean'

# Package manager shortcuts
alias ni='npm install'
alias nid='npm install --save-dev'
alias nig='npm install -g'
alias nun='npm uninstall'
alias nup='npm update'
alias nrun='npm run'
alias ntest='npm test'

# Yarn shortcuts
alias yi='yarn install'
alias ya='yarn add'
alias yad='yarn add --dev'
alias yrm='yarn remove'
alias yup='yarn upgrade'
alias yrun='yarn run'

# pnpm shortcuts
alias pi='pnpm install'
alias pa='pnpm add'
alias pad='pnpm add --save-dev'
alias prm='pnpm remove'
alias pup='pnpm update'
alias prun='pnpm run'

# ----------------------------------------------------------------------------
# npm-global-list - List globally installed npm packages
# ----------------------------------------------------------------------------
npm-global-list() {
    echo "=== Globally installed npm packages ==="
    npm list -g --depth=0
}

# ----------------------------------------------------------------------------
# node-project-init - Initialize a new Node.js project
#
# Arguments:
#   $1 - Project name (optional, defaults to current directory)
#   $2 - Package manager (npm/yarn/pnpm, defaults to npm)
#
# Example:
#   node-project-init my-app pnpm
# ----------------------------------------------------------------------------
node-project-init() {
    local project_name="${1:-.}"
    local pkg_manager="${2:-npm}"

    if [ "$project_name" != "." ]; then
        mkdir -p "$project_name"
        cd "$project_name"
    fi

    echo "Initializing Node.js project with $pkg_manager..."

    case "$pkg_manager" in
        npm)
            npm init -y
            ;;
        yarn)
            yarn init -y
            ;;
        pnpm)
            pnpm init
            ;;
        *)
            echo "Unknown package manager: $pkg_manager"
            echo "Use: npm, yarn, or pnpm"
            return 1
            ;;
    esac

    # Create basic project structure
    mkdir -p src test

    # Create .gitignore
    cat > .gitignore << 'GITIGNORE'
node_modules/
dist/
build/
*.log
.env
.DS_Store
coverage/
.nyc_output/
GITIGNORE

    echo "Project initialized successfully!"
    echo "Structure created:"
    echo "  - src/     (source code)"
    echo "  - test/    (test files)"
    echo "  - .gitignore"
}

# ----------------------------------------------------------------------------
# node-deps-check - Check for outdated dependencies
# ----------------------------------------------------------------------------
node-deps-check() {
    if [ -f package.json ]; then
        echo "=== Checking for outdated dependencies ==="

        if [ -f pnpm-lock.yaml ]; then
            echo "Using pnpm..."
            if ! pnpm outdated 2>/dev/null; then
                echo "pnpm failed (corepack signature issue). Falling back to npm..."
                npm outdated
            fi
        elif [ -f yarn.lock ]; then
            echo "Using yarn..."
            if ! yarn outdated 2>/dev/null; then
                echo "yarn failed (corepack signature issue). Falling back to npm..."
                npm outdated
            fi
        else
            echo "Using npm..."
            npm outdated
        fi
    else
        echo "No package.json found in current directory"
    fi
}

# ----------------------------------------------------------------------------
# node-deps-update - Update dependencies interactively
# ----------------------------------------------------------------------------
node-deps-update() {
    if [ -f package.json ]; then
        echo "=== Updating dependencies ==="

        if [ -f pnpm-lock.yaml ]; then
            echo "Using pnpm..."
            if ! pnpm update --interactive 2>/dev/null; then
                echo "pnpm failed (corepack signature issue). Falling back to npm..."
                npx npm-check-updates -i
            fi
        elif [ -f yarn.lock ]; then
            echo "Using yarn..."
            if ! yarn upgrade-interactive 2>/dev/null; then
                echo "yarn failed (corepack signature issue). Falling back to npm..."
                npx npm-check-updates -i
            fi
        else
            echo "Using npm..."
            npx npm-check-updates -i
        fi
    else
        echo "No package.json found in current directory"
    fi
}

# ----------------------------------------------------------------------------
# node-version - Show Node.js and package manager versions
# ----------------------------------------------------------------------------
node-version() {
    echo "=== Node.js Environment ==="
    echo "Node.js: $(node --version)"
    echo "npm: $(npm --version)"

    # yarn and pnpm may fail due to corepack signature issues
    local yarn_ver=$(yarn --version 2>/dev/null || echo "unavailable (corepack issue)")
    echo "yarn: $yarn_ver"

    local pnpm_ver=$(pnpm --version 2>/dev/null || echo "unavailable (corepack issue)")
    echo "pnpm: $pnpm_ver"

    echo ""
    echo "=== Cache Locations ==="
    echo "npm cache: $(npm config get cache)"

    # yarn and pnpm config may fail due to corepack signature issues
    local yarn_cache=$(yarn config get cache-folder 2>/dev/null || echo "unavailable")
    echo "yarn cache: $yarn_cache"

    local pnpm_store=$(pnpm config get store-dir 2>/dev/null || echo "unavailable")
    echo "pnpm store: $pnpm_store"
}

# Clean up helper functions
unset -f _check_command 2>/dev/null || true

# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
NODE_BASHRC_EOF

# ============================================================================
# Global Package Manager Configuration
# ============================================================================
log_message "Configuring package managers globally..."

# Configure npm
log_command "Configuring npm cache" \
    npm config set cache "${NPM_CACHE_DIR}"

log_command "Configuring npm prefix" \
    npm config set prefix "${NPM_GLOBAL_DIR}"

# Configure yarn - Note: Yarn Berry (2+) uses different config
# We'll set the environment variable instead which works for all versions
export YARN_CACHE_FOLDER="${YARN_CACHE_DIR}"

# Configure pnpm - set store directory for the system (if pnpm is available)
# Note: If pnpm preparation failed earlier, we skip configuration to avoid triggering
# corepack downloads which may fail with signature verification errors.
# Check if pnpm is actually available before attempting configuration.
if command -v pnpm >/dev/null 2>&1 && pnpm --version >/dev/null 2>&1; then
    log_message "Configuring pnpm store..."
    if pnpm config set store-dir "${PNPM_STORE_DIR}" >/dev/null 2>&1; then
        log_message "✓ pnpm configured successfully"
    else
        log_warning "pnpm configuration failed, but pnpm is still usable"
    fi
else
    log_message "pnpm not pre-installed - will be available via corepack on first use"
    log_message "(You can configure it later with: pnpm config set store-dir ${PNPM_STORE_DIR})"
fi

# ============================================================================
# Container Startup Scripts
# ============================================================================
log_message "Creating Node.js startup script..."

# Create startup directory if it doesn't exist
log_command "Creating container startup directory" \
    mkdir -p /etc/container/first-startup

cat > /etc/container/first-startup/20-node-setup.sh << 'EOF'
#!/bin/bash
# Node.js development environment setup

# Set up cache paths
export NPM_CACHE_DIR="/cache/npm"
export YARN_CACHE_DIR="/cache/yarn"
export PNPM_STORE_DIR="/cache/pnpm"
export NPM_GLOBAL_DIR="/cache/npm-global"

# Ensure directories exist with correct permissions
for dir in "${NPM_CACHE_DIR}" "${YARN_CACHE_DIR}" "${PNPM_STORE_DIR}" "${NPM_GLOBAL_DIR}"; do
    if [ ! -d "${dir}" ]; then
        mkdir -p "${dir}"
    fi
done

# Configure package managers for the current user
npm config set cache "${NPM_CACHE_DIR}"
npm config set prefix "${NPM_GLOBAL_DIR}"
# Yarn cache is set via environment variable YARN_CACHE_FOLDER
# Configure pnpm if available (silently skip if corepack signature verification fails)
if command -v pnpm >/dev/null 2>&1; then
    pnpm config set store-dir "${PNPM_STORE_DIR}" 2>/dev/null || true
fi

# Check for Node.js projects and install dependencies
if [ -f ${WORKING_DIR}/package.json ]; then
    echo "=== Node.js Project Detected ==="
    echo "Node.js $(node --version) is installed"
    echo "  npm $(npm --version)"
    echo "  yarn $(yarn --version)"
    # Try to show pnpm version, but silently skip if corepack signature verification fails
    if command -v pnpm >/dev/null 2>&1; then
        pnpm_version=$(pnpm --version 2>/dev/null || echo "not available")
        if [ "$pnpm_version" != "not available" ]; then
            echo "  pnpm $pnpm_version"
        fi
    fi

    cd ${WORKING_DIR}

    # Detect and use the appropriate package manager
    if [ -f pnpm-lock.yaml ]; then
        echo "Installing dependencies with pnpm..."
        pnpm install --frozen-lockfile || pnpm install
    elif [ -f yarn.lock ]; then
        echo "Installing dependencies with yarn..."
        yarn install --frozen-lockfile || yarn install
    elif [ -f package-lock.json ]; then
        echo "Installing dependencies with npm..."
        npm ci || npm install
    else
        echo "No lockfile found. Run one of:"
        echo "  npm install"
        echo "  yarn install"
        echo "  pnpm install"
    fi
fi
EOF
log_command "Setting Node.js startup script permissions" \
    chmod +x /etc/container/first-startup/20-node-setup.sh

# ============================================================================
# Verification Script
# ============================================================================
log_message "Creating Node.js verification script..."

cat > /usr/local/bin/test-node << 'EOF'
#!/bin/bash
echo "=== Node.js Installation Status ==="
if command -v node &> /dev/null; then
    echo "✓ Node.js $(node --version) is installed"
    echo "  Binary: $(which node)"
else
    echo "✗ Node.js is not installed"
fi

echo ""
echo "=== Package Managers ==="
for cmd in npm yarn pnpm; do
    if command -v $cmd &> /dev/null; then
        version=$($cmd --version 2>&1)
        echo "✓ $cmd $version is installed at $(which $cmd)"
    else
        echo "✗ $cmd is not found"
    fi
done

echo ""
echo "=== Cache Directories ==="
echo "NPM cache: ${NPM_CACHE_DIR:-/cache/npm}"
echo "Yarn cache: ${YARN_CACHE_DIR:-/cache/yarn}"
echo "pnpm store: ${PNPM_STORE_DIR:-/cache/pnpm}"
echo "NPM global: ${NPM_GLOBAL_DIR:-/cache/npm-global}"

echo ""
echo "=== Global Packages ==="
if [ -d "${NPM_GLOBAL_DIR:-/cache/npm-global}/lib/node_modules" ]; then
    ls -1 "${NPM_GLOBAL_DIR:-/cache/npm-global}/lib/node_modules" 2>/dev/null | grep -v "^npm$" | sed 's/^/  /' || echo "  No global packages installed"
else
    echo "  No global packages directory found"
fi
EOF
log_command "Setting test-node script permissions" \
    chmod +x /usr/local/bin/test-node

# ============================================================================
# Final Verification
# ============================================================================
log_message "Verifying Node.js installation..."

log_command "Checking Node.js version" \
    /usr/local/bin/node --version || log_warning "Node.js not installed properly"

log_command "Checking npm version" \
    /usr/local/bin/npm --version || log_warning "npm not installed properly"

log_command "Checking yarn version" \
    /usr/local/bin/yarn --version || log_warning "yarn not installed properly"

log_command "Checking pnpm version" \
    /usr/local/bin/pnpm --version || log_warning "pnpm not installed properly"

# ============================================================================
# Final ownership fix
# ============================================================================
log_message "Ensuring correct ownership of Node.js directories..."
log_command "Final ownership fix for Node.js cache directories" \
    chown -R "${USER_UID}:${USER_GID}" "${NPM_CACHE_DIR}" "${YARN_CACHE_DIR}" "${PNPM_STORE_DIR}" "${NPM_GLOBAL_DIR}" || true

# Export directory paths for feature summary (also defined in bashrc for runtime)
export NPM_CACHE_DIR="/cache/npm"
export YARN_CACHE_DIR="/cache/yarn"
export PNPM_STORE_DIR="/cache/pnpm"
export NPM_GLOBAL_DIR="/cache/npm-global"

# Log feature summary
log_feature_summary \
    --feature "Node.js" \
    --version "${NODE_VERSION}" \
    --tools "node,npm,yarn,pnpm,corepack" \
    --paths "${NPM_CACHE_DIR},${YARN_CACHE_DIR},${PNPM_STORE_DIR},${NPM_GLOBAL_DIR}" \
    --env "NPM_CACHE_DIR,YARN_CACHE_DIR,PNPM_STORE_DIR,NPM_GLOBAL_DIR,npm_config_cache,npm_config_prefix" \
    --commands "node,npm,yarn,pnpm,ni,nrun,yi,yrun,pi,prun,node-version,node-project-init,node-deps-check" \
    --next-steps "Run 'test-node' to verify installation. Use 'node-project-init <name> [npm|yarn|pnpm]' to create projects. Dependencies auto-install on container start."

# End logging
log_feature_end

echo ""
echo "Run 'test-node' to verify Node.js installation"
echo "Run 'check-build-logs.sh node' to review installation logs"
