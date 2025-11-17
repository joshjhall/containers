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
#   - TypeScript: typescript, ts-node, tsx
#   - Process Management: pm2, nodemon, concurrently
#   - Profiling: clinic (use Node.js --inspect for debugging)
#   - API Development: express-generator, fastify-cli
#   - Documentation: jsdoc, typedoc
#   - Utilities: npm-check-updates, npkill, serve, http-server
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
safe_add_to_path "${NPM_GLOBAL_DIR}/bin"

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
    npm_install_as_user jest mocha vitest @playwright/test

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

# Add node-dev aliases and helpers
write_bashrc_content /etc/bashrc.d/35-node-dev.sh "Node.js development tools" << 'NODE_DEV_BASHRC_EOF'
# ----------------------------------------------------------------------------
# Node.js Development Tool Aliases and Functions
# ----------------------------------------------------------------------------

# Error protection for interactive shells
set +u  # Don't error on unset variables
set +e  # Don't exit on errors

# ----------------------------------------------------------------------------
# Aliases
# ----------------------------------------------------------------------------
# TypeScript shortcuts
alias tsc='typescript'
alias tsn='ts-node'
alias tsx='tsx'

# Testing shortcuts
alias j='jest'
alias jw='jest --watch'
alias jc='jest --coverage'
alias m='mocha'
alias vt='vitest'
alias vtw='vitest --watch'

# Linting shortcuts
alias esl='eslint'
alias eslf='eslint --fix'
alias pret='prettier --write'
alias pretc='prettier --check'

# Build shortcuts
alias wp='webpack'
alias wpw='webpack --watch'
alias vite='vite'
alias viteb='vite build'
alias vitep='vite preview'

# Process management
alias pm2s='pm2 status'
alias pm2l='pm2 logs'
alias pm2r='pm2 restart'
alias nmon='nodemon'

# Debugging aliases (using built-in Node.js inspector)
alias node-debug='node --inspect'
alias node-debug-brk='node --inspect-brk'
alias node-debug-wait='node --inspect-wait'
alias npm-debug='npm run --node-options="--inspect"'

# ============================================================================
# Template Helper Functions
# ============================================================================

# ----------------------------------------------------------------------------
# load_node_template - Load a Node.js project template file and perform substitutions
#
# Arguments:
#   $1 - Template path relative to templates/node/ (required)
#   $2 - Project name for __PROJECT_NAME__ substitution (optional)
#
# Example:
#   load_node_template "common/gitignore.tmpl"
#   load_node_template "cli/index.ts.tmpl" "my-cli"
# ----------------------------------------------------------------------------
load_node_template() {
    local template_path="$1"
    local project_name="${2:-}"
    local template_file="/tmp/build-scripts/features/templates/node/${template_path}"

    if [ ! -f "$template_file" ]; then
        echo "Error: Template not found: $template_file" >&2
        return 1
    fi

    if [ -n "$project_name" ]; then
        # Replace __PROJECT_NAME__ placeholder with actual project name
        command sed "s/__PROJECT_NAME__/${project_name}/g" "$template_file"
    else
        # No substitution needed, just output the template
        command cat "$template_file"
    fi
}

# ============================================================================
# Project Scaffolding Functions
# ============================================================================

# ----------------------------------------------------------------------------
# node-init - Create a new Node.js project with TypeScript
#
# Arguments:
#   $1 - Project name (required)
#   $2 - Project type (optional: api, cli, lib, web, default: lib)
#
# Example:
#   node-init my-app api
# ----------------------------------------------------------------------------
node-init() {
    if [ -z "$1" ]; then
        echo "Usage: node-init <project-name> [type]"
        echo "Types: api, cli, lib, web"
        return 1
    fi

    local project_name="$1"
    local project_type="${2:-lib}"

    echo "Creating new Node.js project: $project_name (type: $project_type)"

    # Create project directory
    mkdir -p "$project_name"
    cd "$project_name"

    # Initialize package.json
    npm init -y

    # Create basic structure
    mkdir -p src tests docs

    # Install TypeScript and basic dev dependencies
    npm install --save-dev \
        typescript \
        @types/node \
        ts-node \
        tsx \
        eslint \
        @typescript-eslint/parser \
        @typescript-eslint/eslint-plugin \
        prettier \
        jest \
        @types/jest \
        ts-jest

    # Create tsconfig.json
    load_node_template "config/tsconfig.json.tmpl" > tsconfig.json

    # Create jest.config.js
    load_node_template "config/jest.config.js.tmpl" > jest.config.js

    # Create .eslintrc.js
    load_node_template "config/eslintrc.js.tmpl" > .eslintrc.js

    # Create .prettierrc
    load_node_template "config/prettierrc.tmpl" > .prettierrc

    # Create type-specific files
    case "$project_type" in
        api)
            npm install express cors helmet morgan compression
            npm install --save-dev @types/express @types/cors @types/morgan @types/compression
            load_node_template "api/index.ts.tmpl" > src/index.ts
            ;;
        cli)
            npm install commander chalk ora
            npm install --save-dev @types/node
            load_node_template "cli/index.ts.tmpl" "$project_name" > src/index.ts
            chmod +x src/index.ts
            ;;
        web)
            npm install --save-dev vite @vitejs/plugin-react
            load_node_template "config/vite.config.ts.tmpl" > vite.config.ts
            ;;
        *)
            # Default library setup
            load_node_template "lib/index.ts.tmpl" > src/index.ts
            ;;
    esac

    # Update package.json scripts
    npm pkg set scripts.build="tsc"
    npm pkg set scripts.dev="tsx watch src/index.ts"
    npm pkg set scripts.start="node dist/index.js"
    npm pkg set scripts.test="jest"
    npm pkg set scripts.test:watch="jest --watch"
    npm pkg set scripts.test:coverage="jest --coverage"
    npm pkg set scripts.lint="eslint src --ext .ts"
    npm pkg set scripts.lint:fix="eslint src --ext .ts --fix"
    npm pkg set scripts.format="prettier --write 'src/**/*.ts'"
    npm pkg set scripts.format:check="prettier --check 'src/**/*.ts'"

    # Create initial test
    load_node_template "test/index.test.ts.tmpl" > tests/index.test.ts

    echo "Project $project_name created successfully!"
    echo ""
    echo "Available scripts:"
    echo "  npm run dev          - Start development server"
    echo "  npm run build        - Build for production"
    echo "  npm test             - Run tests"
    echo "  npm run lint         - Lint code"
    echo "  npm run format       - Format code"
}

# ----------------------------------------------------------------------------
# node-test-all - Run all tests with coverage across different test runners
# ----------------------------------------------------------------------------
node-test-all() {
    echo "=== Running all test suites ==="

    # Check which test frameworks are available
    if [ -f "jest.config.js" ] || [ -f "jest.config.ts" ]; then
        echo "Running Jest tests..."
        jest --coverage
    fi

    if [ -f "vitest.config.js" ] || [ -f "vitest.config.ts" ]; then
        echo "Running Vitest tests..."
        vitest run --coverage
    fi

    if [ -f "mocha.opts" ] || [ -f ".mocharc.js" ] || [ -f ".mocharc.json" ]; then
        echo "Running Mocha tests..."
        mocha
    fi

    if [ -f "playwright.config.js" ] || [ -f "playwright.config.ts" ]; then
        echo "Running Playwright tests..."
        playwright test
    fi
}

# ----------------------------------------------------------------------------
# node-bundle-analyze - Analyze bundle size
# ----------------------------------------------------------------------------
node-bundle-analyze() {
    if [ -f "webpack.config.js" ]; then
        echo "Analyzing webpack bundle..."
        webpack-bundle-analyzer stats.json
    elif [ -f "vite.config.js" ] || [ -f "vite.config.ts" ]; then
        echo "Building with vite for analysis..."
        vite build --mode analyze
    else
        echo "No webpack or vite config found"
    fi
}

# ----------------------------------------------------------------------------
# node-deps-security - Check for security vulnerabilities
# ----------------------------------------------------------------------------
node-deps-security() {
    echo "=== Checking for security vulnerabilities ==="
    npm audit

    if command -v snyk &> /dev/null; then
        echo ""
        echo "Running Snyk security scan..."
        snyk test
    fi
}

# ----------------------------------------------------------------------------
# node-clean - Clean all build artifacts and caches
# ----------------------------------------------------------------------------
# Unalias node-clean if it exists (conflicts with alias from node.sh)
unalias node-clean 2>/dev/null || true

node-clean() {
    echo "=== Cleaning build artifacts and caches ==="

    # Remove common build directories
    command rm -rf dist/ build/ .next/ out/ coverage/ .cache/ .parcel-cache/

    # Clean package manager caches
    npm cache clean --force

    if [ -f "yarn.lock" ]; then
        if ! yarn cache clean 2>/dev/null; then
            echo "yarn cache clean skipped (corepack signature issue)"
        fi
    fi

    if [ -f "pnpm-lock.yaml" ]; then
        if ! pnpm store prune 2>/dev/null; then
            echo "pnpm store prune skipped (corepack signature issue)"
        fi
    fi

    echo "Cleanup complete!"
}
NODE_DEV_BASHRC_EOF

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
    echo "  Testing: jest, mocha, vitest, playwright"
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
    --tools "typescript,ts-node,tsx,jest,mocha,vitest,playwright,eslint,prettier,webpack,vite,esbuild,rollup,parcel,pm2,nodemon,concurrently,clinic,fastify-cli,jsdoc,typedoc,npm-check-updates" \
    --paths "${NPM_CACHE_DIR},${NPM_GLOBAL_DIR}" \
    --env "NPM_CONFIG_CACHE,NPM_CONFIG_PREFIX" \
    --commands "tsc,ts-node,tsx,jest,mocha,vitest,eslint,prettier,webpack,vite,pm2,nodemon,node-init,node-test-all,node-clean" \
    --next-steps "Run 'test-node-dev' to check installed tools. Use 'node-init <name> [api|cli|lib|web]' to scaffold projects with TypeScript, testing, and linting."

# End logging
log_feature_end

echo ""
echo "Run 'test-node-dev' to check installed tools"
echo "Run 'check-build-logs.sh node-development-tools' to review installation logs"
