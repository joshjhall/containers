#!/bin/bash
# Node.js Development Tools - Essential development utilities for Node.js
#
# Description:
#   Installs comprehensive Node.js development tools for testing, linting,
#   building, and debugging. Tools are installed globally for easy access.
#
# Features:
#   - Testing: jest, mocha, chai, vitest, playwright
#   - Linting/Formatting: eslint, prettier, standard
#   - Build Tools: webpack, vite, esbuild, rollup, parcel
#   - TypeScript: typescript, ts-node, tsx, @types/node
#   - Process Management: pm2, nodemon, concurrently, wait-on
#   - Profiling: clinic (use Node.js --inspect for debugging)
#   - API Development: @nestjs/cli, fastify-cli, json-server
#   - Documentation: jsdoc, typedoc, documentation
#   - Utilities: npm-check-updates, npkill, serve, http-server, live-server, localtunnel
#   - Dependency Analysis: npm-check, depcheck, cost-of-modules
#   - LSP: typescript-language-server
#
# Requirements:
#   - Node.js must be installed (via INCLUDE_NODE=true)
#
set -euo pipefail

# Source standard feature header for user handling
source /tmp/build-scripts/base/feature-header.sh

# Source apt utilities for reliable package installation
source /tmp/build-scripts/base/apt-utils.sh

# Source path utilities for secure PATH management
source /tmp/build-scripts/base/path-utils.sh

# Start logging
log_feature_start "Node.js Development Tools"

# ============================================================================
# Prerequisites Check
# ============================================================================
log_message "Checking prerequisites..."

# Check if Node.js is available
if [ ! -f "/usr/local/bin/node" ]; then
    log_error "Node.js not found at /usr/local/bin/node"
    log_error "The INCLUDE_NODE feature must be enabled before node-dev tools can be installed"
    log_feature_end
    exit 1
fi

# Check if npm is available
if [ ! -f "/usr/local/bin/npm" ]; then
    log_error "npm not found at /usr/local/bin/npm"
    log_error "The INCLUDE_NODE feature must be enabled first"
    log_feature_end
    exit 1
fi

# ============================================================================
# System Dependencies
# ============================================================================
log_message "Installing system dependencies for Node.js dev tools..."

# Install dependencies needed by native Node.js modules
log_message "Installing Node.js development dependencies..."

# Update package lists with retry logic
apt_update

# Install Node.js development dependencies with retry logic
# build-essential provides gcc, g++, make, binutils needed for native addons
# python3 needed for node-gyp (build tool for native addons)
# Image processing libraries needed for canvas, sharp, and similar packages
apt_install \
    build-essential \
    python3 \
    python3-pip \
    libcairo2-dev \
    libpango1.0-dev \
    libjpeg-dev \
    libgif-dev \
    librsvg2-dev \
    libpixman-1-dev

# ============================================================================
# Node.js Development Tools Installation
# ============================================================================
log_message "Installing Node.js development tools..."

# Set npm global directory from cache
export NPM_GLOBAL_DIR="/cache/npm-global"
export PATH="${NPM_GLOBAL_DIR}/bin:$PATH"

# Configure npm to use global directory
log_command "Configuring npm global directory" \
    /usr/local/bin/npm config set prefix "${NPM_GLOBAL_DIR}"

log_message "Installing essential Node.js development tools..."

# Get cache directories
NPM_CACHE_DIR="${NPM_CACHE_DIR:-/cache/npm}"
NPM_GLOBAL_DIR="${NPM_GLOBAL_DIR:-/cache/npm-global}"

# Helper function to install npm packages as user
npm_install_as_user() {
    local packages="$*"
    su - "${USERNAME}" -c "export NPM_CONFIG_CACHE='${NPM_CACHE_DIR}' NPM_CONFIG_PREFIX='${NPM_GLOBAL_DIR}' && /usr/local/bin/npm install -g ${packages}"
}

# TypeScript and related tools
log_command "Installing TypeScript toolchain" \
    npm_install_as_user typescript ts-node tsx @types/node

# Testing frameworks
log_command "Installing testing frameworks" \
    npm_install_as_user jest mocha chai vitest @playwright/test

# Linting and formatting
log_command "Installing linting and formatting tools" \
    npm_install_as_user eslint prettier standard

# Build tools
log_command "Installing build tools" \
    npm_install_as_user webpack webpack-cli vite esbuild rollup parcel

# Process management and monitoring
log_command "Installing process management tools" \
    npm_install_as_user pm2 nodemon concurrently wait-on

# Debugging and profiling
# Note: ndb removed as it's unmaintained (last update 6 years ago)
# Modern debugging should use Node.js built-in --inspect with Chrome DevTools
log_command "Installing profiling tools" \
    npm_install_as_user clinic

# API development tools
# Note: express-generator has deprecated dependencies but is still officially maintained
log_command "Installing API development tools" \
    npm_install_as_user @nestjs/cli fastify-cli json-server

# Documentation generators
log_command "Installing documentation tools" \
    npm_install_as_user jsdoc typedoc documentation

# Utility tools
log_command "Installing utility tools" \
    npm_install_as_user npm-check-updates npkill serve http-server live-server localtunnel

# Package analysis tools
log_command "Installing package analysis tools" \
    npm_install_as_user npm-check depcheck cost-of-modules

# ============================================================================
# Create symlinks for all installed tools
# ============================================================================
log_message "Creating symlinks for development tools..."

# Find all executables in the global npm bin directory and create symlinks
if [ -d "${NPM_GLOBAL_DIR}/bin" ]; then
    for tool in "${NPM_GLOBAL_DIR}/bin"/*; do
        if [ -f "$tool" ] && [ -x "$tool" ]; then
            tool_name=$(basename "$tool")
            if [ ! -L "/usr/local/bin/${tool_name}" ]; then
                create_symlink "$tool" "/usr/local/bin/${tool_name}" "${tool_name} Node.js tool"
            fi
        fi
    done
fi

# ============================================================================
# Shell Aliases and Functions
# ============================================================================
log_message "Setting up Node.js development helpers..."

# Ensure /etc/bashrc.d exists
log_command "Creating bashrc.d directory" \
    mkdir -p /etc/bashrc.d

# Add node-dev aliases and helpers (content in lib/bashrc/node-dev.sh)
write_bashrc_content /etc/bashrc.d/35-node-dev.sh "Node.js development tools" \
    < /tmp/build-scripts/features/lib/bashrc/node-dev.sh

log_command "Setting Node.js dev bashrc script permissions" \
    chmod +x /etc/bashrc.d/35-node-dev.sh

# ============================================================================
# Container Startup Scripts
# ============================================================================
log_message "Creating node-dev startup script..."

log_command "Creating container startup directory" \
    mkdir -p /etc/container/first-startup

command cat > /etc/container/first-startup/25-node-dev-setup.sh << 'NODE_DEV_STARTUP_EOF'
#!/bin/bash
# Node.js development tools configuration
if command -v node &> /dev/null; then
    echo "=== Node.js Development Tools ==="

    # Check for TypeScript project
    if [ -f ${WORKING_DIR}/tsconfig.json ]; then
        echo "TypeScript project detected!"
        echo "TypeScript $(tsc --version) is installed"

        # Check if this is a new project without dependencies
        if [ ! -d ${WORKING_DIR}/node_modules ]; then
            echo "No node_modules found. Run 'npm install' to install dependencies"
        fi
    fi

    # Check for various config files and provide hints
    if [ -f ${WORKING_DIR}/webpack.config.js ]; then
        echo "Webpack configuration detected"
        echo "Use 'npm run build' or 'webpack' to build"
    fi

    if [ -f ${WORKING_DIR}/vite.config.js ] || [ -f ${WORKING_DIR}/vite.config.ts ]; then
        echo "Vite configuration detected"
        echo "Use 'npm run dev' or 'vite' for development"
    fi

    if [ -f ${WORKING_DIR}/.eslintrc.js ] || [ -f ${WORKING_DIR}/.eslintrc.json ]; then
        echo "ESLint configuration detected"
        echo "Use 'npm run lint' or 'eslint' to lint code"
    fi

    if [ -f ${WORKING_DIR}/jest.config.js ] || [ -f ${WORKING_DIR}/jest.config.ts ]; then
        echo "Jest configuration detected"
        echo "Use 'npm test' or 'jest' to run tests"
    fi

    # Show available dev tools
    echo ""
    echo "Node.js development tools available:"
    echo "  TypeScript: tsc, ts-node, tsx"
    echo "  Testing: jest, mocha, chai, vitest, playwright"
    echo "  Linting: eslint, prettier, standard"
    echo "  Building: webpack, vite, esbuild, rollup, parcel"
    echo "  Process: pm2, nodemon, concurrently"
    echo ""
    echo "Create new projects:"
    echo "  node-init <name> [api|cli|lib|web]"
fi
NODE_DEV_STARTUP_EOF
log_command "Setting Node.js dev startup script permissions" \
    chmod +x /etc/container/first-startup/25-node-dev-setup.sh

# ============================================================================
# Verification Script
# ============================================================================
log_message "Creating node-dev verification script..."

command cat > /usr/local/bin/test-node-dev << 'NODE_DEV_TEST_EOF'
#!/bin/bash
echo "=== Node.js Development Tools Status ==="

# Check TypeScript
echo ""
echo "TypeScript tools:"
for tool in tsc ts-node tsx; do
    if command -v $tool &> /dev/null; then
        version=$($tool --version 2>&1 | head -1)
        echo "✓ $tool: $version"
    else
        echo "✗ $tool is not found"
    fi
done

# Check testing tools
echo ""
echo "Testing tools:"
for tool in jest mocha vitest playwright; do
    if command -v $tool &> /dev/null; then
        if [ "$tool" = "jest" ] || [ "$tool" = "vitest" ]; then
            version=$($tool --version 2>&1)
        else
            version=$($tool --version 2>&1 | head -1)
        fi
        echo "✓ $tool: $version"
    else
        echo "✗ $tool is not found"
    fi
done

# Check linting tools
echo ""
echo "Linting/Formatting tools:"
for tool in eslint prettier standard; do
    if command -v $tool &> /dev/null; then
        version=$($tool --version 2>&1 | head -1)
        echo "✓ $tool: $version"
    else
        echo "✗ $tool is not found"
    fi
done

# Check build tools
echo ""
echo "Build tools:"
for tool in webpack vite esbuild rollup parcel; do
    if command -v $tool &> /dev/null; then
        version=$($tool --version 2>&1 | head -1)
        echo "✓ $tool: $version"
    else
        echo "✗ $tool is not found"
    fi
done

# Check process management
echo ""
echo "Process management:"
for tool in pm2 nodemon; do
    if command -v $tool &> /dev/null; then
        version=$($tool --version 2>&1 | head -1)
        echo "✓ $tool: $version"
    else
        echo "✗ $tool is not found"
    fi
done

echo ""
echo "Run 'node-dev-list' to see all installed Node.js development tools"
NODE_DEV_TEST_EOF
log_command "Setting test-node-dev script permissions" \
    chmod +x /usr/local/bin/test-node-dev

# Add helper to list all node dev tools
command cat > /usr/local/bin/node-dev-list << 'NODE_DEV_LIST_EOF'
#!/bin/bash
echo "=== Installed Node.js Development Tools ==="
echo ""
echo "Global npm packages:"
npm list -g --depth=0 | grep -v "npm@" | command sed 's/├── //g' | command sed 's/└── //g' | sort
NODE_DEV_LIST_EOF
log_command "Setting node-dev-list script permissions" \
    chmod +x /usr/local/bin/node-dev-list

# ============================================================================
# TypeScript Language Server (for IDE support)
# ============================================================================
log_message "Installing TypeScript language server for IDE support..."

# typescript-language-server: LSP wrapper for TypeScript's tsserver
# Note: typescript is already installed above, just need the LSP wrapper
log_command "Installing typescript-language-server" \
    npm_install_as_user typescript-language-server

# Verify LSP installation
if command -v typescript-language-server &>/dev/null; then
    log_message "TypeScript LSP installed successfully"
else
    log_warning "TypeScript LSP installation could not be verified"
fi

# ============================================================================
# Final Verification
# ============================================================================
log_message "Verifying key Node.js development tools..."

log_command "Checking TypeScript version" \
    /usr/local/bin/tsc --version || log_warning "TypeScript not installed"

log_command "Checking Jest version" \
    /usr/local/bin/jest --version || log_warning "Jest not installed"

log_command "Checking ESLint version" \
    /usr/local/bin/eslint --version || log_warning "ESLint not installed"

log_command "Checking Webpack version" \
    /usr/local/bin/webpack --version || log_warning "Webpack not installed"

# ============================================================================
# Final ownership fix
# ============================================================================
log_message "Ensuring correct ownership of Node.js directories..."
log_command "Final ownership fix for Node.js cache directories" \
    chown -R "${USER_UID}:${USER_GID}" "${NPM_CACHE_DIR}" "${NPM_GLOBAL_DIR}" || true

# Log feature summary
# Export directory paths for feature summary (also defined in parent node.sh)
export NPM_CACHE_DIR="/cache/npm"
export NPM_GLOBAL_DIR="/cache/npm-global"

log_feature_summary \
    --feature "Node.js Development Tools" \
    --tools "typescript,ts-node,tsx,jest,mocha,chai,vitest,playwright,eslint,prettier,webpack,vite,esbuild,rollup,parcel,pm2,nodemon,concurrently,clinic,fastify-cli,jsdoc,typedoc,npm-check-updates" \
    --paths "${NPM_CACHE_DIR},${NPM_GLOBAL_DIR}" \
    --env "NPM_CONFIG_CACHE,NPM_CONFIG_PREFIX" \
    --commands "tsc,ts-node,tsx,jest,mocha,vitest,eslint,prettier,webpack,vite,pm2,nodemon,node-init,node-test-all,node-clean" \
    --next-steps "Run 'test-node-dev' to check installed tools. Use 'node-init <name> [api|cli|lib|web]' to scaffold projects with TypeScript, testing, and linting."

# End logging
log_feature_end

echo ""
echo "Run 'test-node-dev' to check installed tools"
echo "Run 'check-build-logs.sh node-development-tools' to review installation logs"
