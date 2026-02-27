# shellcheck disable=SC2164
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
