#!/bin/bash
# Node.js - JavaScript runtime with npm, yarn, and pnpm
#
# Description:
#   Installs Node.js via NodeSource repository with modern package managers.
#   Configures cache directories for optimal container performance.
#
# Features:
#   - Node.js runtime via NodeSource repository
#   - npm (included with Node.js)
#   - yarn and pnpm (via corepack)
#   - Automatic dependency detection and installation
#   - Cache optimization for containerized environments
#
# Environment Variables:
#   - NODE_VERSION: Major version number (default: 22 LTS, minimum: 18)
#
# Supported Versions:
#   - 22.x (current LTS)
#   - 20.x (previous LTS)
#   - 18.x (maintenance LTS)
#
set -euo pipefail

# Source standard feature header for user handling
source /tmp/build-scripts/base/feature-header.sh

# ============================================================================
# Version Configuration
# ============================================================================
# Node.js version (major version only)
NODE_VERSION="${NODE_VERSION:-22}"

# Start logging
log_feature_start "Node.js" "${NODE_VERSION}"

# Ensure Node.js version is 18 or higher (16 EOL was April 2024)
if [ "$NODE_VERSION" -lt 18 ]; then
    log_error "Node.js version must be 18 or higher"
    log_error "Node.js 16 reached end-of-life in April 2024"
    log_error "Requested version: ${NODE_VERSION}"
    log_feature_end
    exit 1
fi

# ============================================================================
# System Dependencies
# ============================================================================
log_message "Installing system dependencies for Node.js..."

# Install dependencies needed by Node.js and native modules
log_command "Updating package lists" \
    apt-get update

log_command "Installing Node.js dependencies" \
    apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    gnupg

# ============================================================================
# Node.js Installation
# ============================================================================
log_message "Installing Node.js ${NODE_VERSION}..."

# Install Node.js using NodeSource repository
log_command "Adding NodeSource repository" \
    bash -c "curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash -"

log_command "Installing Node.js" \
    apt-get install -y nodejs

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

log_command "Preparing pnpm" \
    corepack prepare pnpm@latest --activate

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

# Create cache directories with correct ownership
log_command "Creating Node.js cache directories" \
    mkdir -p "${NPM_CACHE_DIR}" "${YARN_CACHE_DIR}" "${PNPM_STORE_DIR}" "${NPM_GLOBAL_DIR}"

log_command "Setting cache directory ownership" \
    chown -R ${USER_UID}:${USER_GID} "${NPM_CACHE_DIR}" "${YARN_CACHE_DIR}" "${PNPM_STORE_DIR}" "${NPM_GLOBAL_DIR}"

log_message "Node.js cache paths:"
log_message "  NPM cache: ${NPM_CACHE_DIR}"
log_message "  Yarn cache: ${YARN_CACHE_DIR}"
log_message "  pnpm store: ${PNPM_STORE_DIR}"
log_message "  NPM global: ${NPM_GLOBAL_DIR}"

# ============================================================================
# Create symlinks for Node.js binaries
# ============================================================================
log_message "Creating Node.js symlinks..."

# Node.js installs to /usr/bin via apt
NODE_BIN_DIR="/usr/bin"

# Create /usr/local/bin symlinks for consistency with other languages
for cmd in node npm npx yarn pnpm; do
    if [ -f "${NODE_BIN_DIR}/${cmd}" ]; then
        create_symlink "${NODE_BIN_DIR}/${cmd}" "/usr/local/bin/${cmd}" "${cmd} command"
    fi
done

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
alias yarn-clean='yarn cache clean'
alias pnpm-clean='pnpm store prune'
alias node-clean='npm-clean && yarn-clean && pnpm-clean'

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
            pnpm outdated
        elif [ -f yarn.lock ]; then
            echo "Using yarn..."
            yarn outdated
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
            pnpm update --interactive
        elif [ -f yarn.lock ]; then
            echo "Using yarn..."
            yarn upgrade-interactive
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
    echo "yarn: $(yarn --version)"
    echo "pnpm: $(pnpm --version)"
    echo ""
    echo "=== Cache Locations ==="
    echo "npm cache: $(npm config get cache)"
    echo "yarn cache: $(yarn config get cache-folder)"
    echo "pnpm store: $(pnpm config get store-dir)"
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

# Configure pnpm - set store directory for the system
log_command "Configuring pnpm store" \
    pnpm config set store-dir "${PNPM_STORE_DIR}"

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
pnpm config set store-dir "${PNPM_STORE_DIR}"

# pnpm is configured system-wide, no user-specific setup needed

# Check for Node.js projects and install dependencies
if [ -f ${WORKING_DIR}/package.json ]; then
    echo "=== Node.js Project Detected ==="
    echo "Node.js $(node --version) is installed"
    echo "  npm $(npm --version)"
    echo "  yarn $(yarn --version)"
    echo "  pnpm $(pnpm --version)"

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
    chown -R ${USER_UID}:${USER_GID} "${NPM_CACHE_DIR}" "${YARN_CACHE_DIR}" "${PNPM_STORE_DIR}" "${NPM_GLOBAL_DIR}" || true

# End logging
log_feature_end

echo ""
echo "Run 'test-node' to verify Node.js installation"
echo "Run 'check-build-logs.sh node' to review installation logs"
