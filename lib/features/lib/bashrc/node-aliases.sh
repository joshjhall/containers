
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
        cd "$project_name" || return
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
    load_node_template "common/gitignore.tmpl" > .gitignore

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
    local yarn_ver
    yarn_ver=$(yarn --version 2>/dev/null || echo "unavailable (corepack issue)")
    echo "yarn: $yarn_ver"

    local pnpm_ver
    pnpm_ver=$(pnpm --version 2>/dev/null || echo "unavailable (corepack issue)")
    echo "pnpm: $pnpm_ver"

    echo ""
    echo "=== Cache Locations ==="
    echo "npm cache: $(npm config get cache)"

    # yarn and pnpm config may fail due to corepack signature issues
    local yarn_cache
    yarn_cache=$(yarn config get cache-folder 2>/dev/null || echo "unavailable")
    echo "yarn cache: $yarn_cache"

    local pnpm_store
    pnpm_store=$(pnpm config get store-dir 2>/dev/null || echo "unavailable")
    echo "pnpm store: $pnpm_store"
}


# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
