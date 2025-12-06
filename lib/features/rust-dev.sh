#!/bin/bash
# Rust Development Tools - Advanced development utilities for Rust
#
# Description:
#   Installs additional development tools for Rust programming, including
#   code analysis, formatting, testing, and parsing tools. These complement
#   the base Rust installation with productivity-enhancing utilities.
#
# Tools Installed:
#   - tree-sitter-cli: Incremental parsing library and code analysis
#   - cargo-watch: Automatically rebuild on file changes
#   - cargo-expand: Expand macros to see generated code
#   - cargo-outdated: Check for outdated dependencies
#   - cargo-release: Semantic versioning and crate publishing
#   - sccache: Shared compilation cache for faster builds
#   - bacon: Background rust code checker
#   - tokei: Code statistics tool
#   - hyperfine: Command-line benchmarking tool
#   - just: Modern command runner (like make)
#   - mdbook: Create books from markdown files
#   - taplo-cli: TOML formatter and linter
#
# Common Commands:
#   - cargo watch -x run: Auto-rebuild and run on changes
#   - cargo add <crate>: Add dependency to Cargo.toml (built into cargo)
#   - cargo expand: Show macro-expanded code
#   - cargo outdated: List outdated dependencies
#   - bacon: Run continuous background compilation
#   - tokei: Count lines of code by language
#   - hyperfine <cmd>: Benchmark command execution
#   - just: Run project tasks
#
# Requirements:
#   - Rust/Cargo must be installed (via INCLUDE_RUST=true)
#
# Note:
#   These tools significantly improve Rust development workflow,
#   especially for large projects or continuous development.
#
set -euo pipefail

# Source standard feature header for user handling
source /tmp/build-scripts/base/feature-header.sh

# Source apt utilities for reliable package installation
source /tmp/build-scripts/base/apt-utils.sh

# Start logging
log_feature_start "Rust Development Tools"

# ============================================================================
# Prerequisites Check
# ============================================================================
log_message "Checking prerequisites..."

# Check if Rust/Cargo is available
if [ ! -f "/usr/local/bin/cargo" ]; then
    log_error "cargo not found at /usr/local/bin/cargo"
    log_error "The INCLUDE_RUST feature must be enabled before rust-dev tools can be installed"
    log_feature_end
    exit 1
fi

# ============================================================================
# System Dependencies
# ============================================================================
# Update package lists with retry logic
apt_update

log_message "Installing system dependencies for Rust dev tools"
# build-essential needed for compiling Rust crates with C dependencies
# pkg-config needed for finding system libraries
# libssl-dev needed for crates using OpenSSL
# cmake needed for some complex crates
apt_install \
    build-essential \
    pkg-config \
    libssl-dev \
    cmake

# ============================================================================
# Rust Development Tools Installation
# ============================================================================
log_message "Installing Rust development tools via Cargo..."

# Use the cargo symlink we created
export CARGO_HOME="/cache/cargo"
export RUSTUP_HOME="/cache/rustup"

# Core development tools
# Run as the user to ensure correct ownership
log_command "Installing tree-sitter-cli" \
    su - "${USERNAME}" -c "export CARGO_HOME='${CARGO_HOME}' RUSTUP_HOME='${RUSTUP_HOME}' && /usr/local/bin/cargo install tree-sitter-cli"

log_command "Installing cargo-watch" \
    su - "${USERNAME}" -c "export CARGO_HOME='${CARGO_HOME}' RUSTUP_HOME='${RUSTUP_HOME}' && /usr/local/bin/cargo install cargo-watch"

log_command "Installing cargo-expand" \
    su - "${USERNAME}" -c "export CARGO_HOME='${CARGO_HOME}' RUSTUP_HOME='${RUSTUP_HOME}' && /usr/local/bin/cargo install cargo-expand"

log_command "Installing cargo-outdated" \
    su - "${USERNAME}" -c "export CARGO_HOME='${CARGO_HOME}' RUSTUP_HOME='${RUSTUP_HOME}' && /usr/local/bin/cargo install cargo-outdated"

log_command "Installing cargo-audit" \
    su - "${USERNAME}" -c "export CARGO_HOME='${CARGO_HOME}' RUSTUP_HOME='${RUSTUP_HOME}' && /usr/local/bin/cargo install cargo-audit"

log_command "Installing cargo-deny" \
    su - "${USERNAME}" -c "export CARGO_HOME='${CARGO_HOME}' RUSTUP_HOME='${RUSTUP_HOME}' && /usr/local/bin/cargo install cargo-deny"

log_command "Installing cargo-geiger" \
    su - "${USERNAME}" -c "export CARGO_HOME='${CARGO_HOME}' RUSTUP_HOME='${RUSTUP_HOME}' && /usr/local/bin/cargo install cargo-geiger"

log_command "Installing bacon" \
    su - "${USERNAME}" -c "export CARGO_HOME='${CARGO_HOME}' RUSTUP_HOME='${RUSTUP_HOME}' && /usr/local/bin/cargo install bacon"

log_command "Installing tokei" \
    su - "${USERNAME}" -c "export CARGO_HOME='${CARGO_HOME}' RUSTUP_HOME='${RUSTUP_HOME}' && /usr/local/bin/cargo install tokei"

log_command "Installing hyperfine" \
    su - "${USERNAME}" -c "export CARGO_HOME='${CARGO_HOME}' RUSTUP_HOME='${RUSTUP_HOME}' && /usr/local/bin/cargo install hyperfine"

log_command "Installing just" \
    su - "${USERNAME}" -c "export CARGO_HOME='${CARGO_HOME}' RUSTUP_HOME='${RUSTUP_HOME}' && /usr/local/bin/cargo install just"

log_command "Installing sccache" \
    su - "${USERNAME}" -c "export CARGO_HOME='${CARGO_HOME}' RUSTUP_HOME='${RUSTUP_HOME}' && /usr/local/bin/cargo install sccache"

log_command "Installing mdbook" \
    su - "${USERNAME}" -c "export CARGO_HOME='${CARGO_HOME}' RUSTUP_HOME='${RUSTUP_HOME}' && /usr/local/bin/cargo install mdbook"

# Pin to 0.25.21 to avoid trycmd/toml_edit type inference conflict in 0.25.22
# See: https://github.com/crate-ci/cargo-release/issues
log_command "Installing cargo-release" \
    su - "${USERNAME}" -c "export CARGO_HOME='${CARGO_HOME}' RUSTUP_HOME='${RUSTUP_HOME}' && /usr/local/bin/cargo install cargo-release --version 0.25.21"

# Install taplo-cli (TOML formatter/linter) if not already installed by dev-tools
if ! command -v taplo &> /dev/null; then
    log_command "Installing taplo-cli" \
        su - "${USERNAME}" -c "export CARGO_HOME='${CARGO_HOME}' RUSTUP_HOME='${RUSTUP_HOME}' && /usr/local/bin/cargo install taplo-cli"
else
    log_message "taplo already installed, skipping..."
fi

# Create symlinks for the installed tools
log_message "Creating symlinks for Rust dev tools..."
for tool in tree-sitter cargo-watch cargo-expand cargo-outdated cargo-audit cargo-deny cargo-geiger bacon tokei hyperfine just sccache mdbook cargo-release taplo; do
    if [ -f "${CARGO_HOME}/bin/${tool}" ]; then
        create_symlink "${CARGO_HOME}/bin/${tool}" "/usr/local/bin/${tool}" "${tool} Rust dev tool"
    fi
done

# ============================================================================
# Verification and Helpers
# ============================================================================
# Create verification script
command cat > /usr/local/bin/test-rust-dev << 'EOF'
#!/bin/bash
echo "=== Rust Development Tools Status ==="
tools=(
    "tree-sitter"
    "cargo-watch"
    "cargo-expand"
    "cargo-outdated"
    "cargo-audit"
    "cargo-deny"
    "cargo-geiger"
    "bacon"
    "tokei"
    "hyperfine"
    "just"
    "sccache"
    "mdbook"
    "cargo-release"
    "taplo"
)

installed=0
for tool in "${tools[@]}"; do
    if command -v "$tool" &> /dev/null; then
        echo "✓ $tool is installed"
        ((installed++))
    else
        echo "✗ $tool is not found"
    fi
done

echo ""
echo "Installed: $installed/${#tools[@]} tools"
EOF

log_command "Setting test-rust-dev script permissions" \
    chmod +x /usr/local/bin/test-rust-dev

# ============================================================================
# Shell Helpers
# ============================================================================
echo "=== Setting up Rust development helpers ==="

# Ensure /etc/bashrc.d exists
log_command "Creating bashrc.d directory" \
    mkdir -p /etc/bashrc.d

# Add rust-dev aliases and helpers
write_bashrc_content /etc/bashrc.d/35-rust-dev.sh "Rust development tools configuration" << 'RUST_DEV_BASHRC_EOF'
# ----------------------------------------------------------------------------
# Rust Development Tool Aliases and Functions
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
# Rust Development Tool Aliases
# ----------------------------------------------------------------------------
# Tree-sitter aliases
alias ts='tree-sitter'
alias ts-parse='tree-sitter parse'
alias ts-test='tree-sitter test'
alias ts-highlight='tree-sitter highlight'

# Cargo extensions
alias cw='cargo watch'
alias cwx='cargo watch -x'
alias cwr='cargo watch -x run'
alias cwt='cargo watch -x test'
alias cwc='cargo watch -x check'

# Other tools
alias loc='tokei'
alias bench='hyperfine'

# Unified workflow aliases
alias rust-lint-all='cargo clippy --all-targets --all-features'
alias rust-security-check='cargo audit && cargo deny check 2>/dev/null || true && command -v cargo-geiger >/dev/null && cargo geiger --output-format GitHubMarkdown 2>/dev/null || true'
alias rust-watch='cargo watch -x check -x test'

# ----------------------------------------------------------------------------
# ts-parse-file - Parse a file and show its syntax tree
#
# Arguments:
#   $1 - Source file to parse (required)
#   $2 - Language (optional, auto-detected by extension)
#
# Example:
#   ts-parse-file main.py
#   ts-parse-file config.json json
# ----------------------------------------------------------------------------
ts-parse-file() {
    if [ -z "$1" ]; then
        echo "Usage: ts-parse-file <source-file> [language]"
        return 1
    fi

    local file="$1"
    local lang="${2:-}"

    if [ ! -f "$file" ]; then
        echo "Error: File '$file' not found"
        return 1
    fi

    if [ -n "$lang" ]; then
        tree-sitter parse "$file" --scope source."$lang"
    else
        tree-sitter parse "$file"
    fi
}

# ----------------------------------------------------------------------------
# ts-query - Run a tree-sitter query on a file
#
# Arguments:
#   $1 - Source file (required)
#   $2 - Query pattern (required)
#
# Example:
#   ts-query main.py '(function_definition name: (identifier) @name)'
# ----------------------------------------------------------------------------
ts-query() {
    if [ -z "$1" ] || [ -z "$2" ]; then
        echo "Usage: ts-query <file> <query-pattern>"
        return 1
    fi

    local file="$1"
    local query="$2"

    echo "Running query on $file:"
    echo "$query" | tree-sitter query "$file" -
}

# ----------------------------------------------------------------------------
# load_rust_template - Load a Rust project template with variable substitution
#
# Arguments:
#   $1 - Template path relative to templates/rust/ (required)
#   $2 - Language/project name for substitution (optional)
#
# Example:
#   load_rust_template "treesitter/grammar.js.tmpl" "mylang"
#   load_rust_template "just/justfile.tmpl"
# ----------------------------------------------------------------------------
load_rust_template() {
    local template_path="$1"
    local lang_name="${2:-}"
    local template_file="/tmp/build-scripts/features/templates/rust/${template_path}"

    if [ ! -f "$template_file" ]; then
        echo "Error: Template not found: $template_file" >&2
        return 1
    fi

    if [ -n "$lang_name" ]; then
        command sed "s/__LANG_NAME__/${lang_name}/g" "$template_file"
    else
        command cat "$template_file"
    fi
}

# ----------------------------------------------------------------------------
# ts-init-grammar - Initialize a new tree-sitter grammar project
#
# Arguments:
#   $1 - Language name (required)
#
# Example:
#   ts-init-grammar mylang
# ----------------------------------------------------------------------------
ts-init-grammar() {
    if [ -z "$1" ]; then
        echo "Usage: ts-init-grammar <language-name>"
        return 1
    fi

    local lang="$1"
    local dir="tree-sitter-$lang"

    if [ -d "$dir" ]; then
        echo "Error: Directory '$dir' already exists"
        return 1
    fi

    echo "Initializing tree-sitter grammar for '$lang'..."
    mkdir -p "$dir"
    cd "$dir"

    # Create grammar.js from template
    load_rust_template "treesitter/grammar.js.tmpl" "$lang" > grammar.js

    echo "Grammar initialized in $dir/"
    echo "Next steps:"
    echo "  1. Edit grammar.js to define your language"
    echo "  2. Run 'tree-sitter generate' to create the parser"
    echo "  3. Run 'tree-sitter test' to test your grammar"
}

# ----------------------------------------------------------------------------
# rust-dev-enable-sccache - Enable sccache for faster Rust builds
#
# Sets up environment to use sccache as the Rust compiler wrapper
# ----------------------------------------------------------------------------
rust-dev-enable-sccache() {
    export RUSTC_WRAPPER=sccache
    export SCCACHE_DIR="${SCCACHE_DIR:-/cache/sccache}"
    mkdir -p "$SCCACHE_DIR"
    echo "sccache enabled for Rust builds"
    echo "Cache directory: $SCCACHE_DIR"
    sccache --show-stats
}

# ----------------------------------------------------------------------------
# cargo-check-updates - Check all dependency updates
#
# Shows outdated dependencies and suggests updates
# ----------------------------------------------------------------------------
cargo-check-updates() {
    echo "=== Checking for outdated dependencies ==="
    cargo outdated
    echo ""
    echo "To update dependencies, use:"
    echo "  cargo update              # Update to latest compatible versions"
    echo "  cargo upgrade             # Update to latest versions (may break)"
}

# ----------------------------------------------------------------------------
# just-init - Initialize a new justfile for project automation
# ----------------------------------------------------------------------------
just-init() {
    if [ -f "justfile" ]; then
        echo "justfile already exists"
        return 1
    fi

    # Create justfile from template
    load_rust_template "just/justfile.tmpl" > justfile

    echo "Created justfile with common Rust project commands"
    echo "Run 'just' to see available commands"
}

# Clean up helper functions
unset -f _check_command 2>/dev/null || true

# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
RUST_DEV_BASHRC_EOF

log_command "Setting Rust dev bashrc script permissions" \
    chmod +x /etc/bashrc.d/35-rust-dev.sh

# ============================================================================
# Container Startup Scripts
# ============================================================================
echo "=== Creating rust-dev startup script ==="

# Create startup directory if it doesn't exist
log_command "Creating startup directory" \
    mkdir -p /etc/container/first-startup

command cat > /etc/container/first-startup/20-rust-dev-setup.sh << 'EOF'
#!/bin/bash
# Rust development tools configuration
if command -v cargo &> /dev/null; then
    echo "=== Rust Development Tools ==="

    # Check which tools are installed
    tools_found=()
    [ -x "$(command -v tree-sitter)" ] && tools_found+=("tree-sitter")
    [ -x "$(command -v cargo-watch)" ] && tools_found+=("cargo-watch")
    [ -x "$(command -v bacon)" ] && tools_found+=("bacon")
    [ -x "$(command -v just)" ] && tools_found+=("just")
    [ -x "$(command -v tokei)" ] && tools_found+=("tokei")
    [ -x "$(command -v sccache)" ] && tools_found+=("sccache")
    [ -x "$(command -v mdbook)" ] && tools_found+=("mdbook")

    if [ ${#tools_found[@]} -gt 0 ]; then
        echo "Installed tools: ${tools_found[*]}"
        echo ""
        echo "Quick commands:"
        echo "  cargo watch -x run        - Auto-rebuild on changes"
        echo "  bacon                     - Background compilation"
        echo "  just                      - Run project tasks"
        echo "  tokei                     - Count lines of code"
        echo "  rust-dev-enable-sccache   - Enable compilation cache"
    fi

    # Check for Rust projects
    if [ -f ${WORKING_DIR}/Cargo.toml ]; then
        echo ""
        echo "Rust project detected!"

        # Suggest creating a justfile if it doesn't exist
        if [ ! -f ${WORKING_DIR}/justfile ] && command -v just &> /dev/null; then
            echo "Tip: Run 'just-init' to create a justfile for common tasks"
        fi

        # Enable sccache if available
        if command -v sccache &> /dev/null && [ -z "$RUSTC_WRAPPER" ]; then
            echo "Tip: Run 'rust-dev-enable-sccache' for faster builds"
        fi
    fi

    # Check for tree-sitter grammar projects
    if compgen -G "${WORKING_DIR}/tree-sitter-*" > /dev/null || [ -f ${WORKING_DIR}/grammar.js ]; then
        echo ""
        echo "Tree-sitter grammar project detected!"
        echo "Use 'tree-sitter generate' to build your parser"
    fi
fi
EOF

log_command "Setting startup script permissions" \
    chmod +x /etc/container/first-startup/20-rust-dev-setup.sh

# ============================================================================
# Final ownership fix
# ============================================================================
# Note: rust-dev does not create cache directories itself, it relies on the base rust feature
# This final ownership fix ensures cargo cache is owned correctly after tool installations
log_message "Ensuring correct ownership of Rust directories..."
log_command "Final ownership fix for cargo cache" \
    chown -R "${USER_UID}:${USER_GID}" "${CARGO_HOME}" "${RUSTUP_HOME}" || true

# Log feature summary
# Export directory paths for feature summary (also defined in parent rust.sh)
export CARGO_HOME="/cache/cargo"
export RUSTUP_HOME="/cache/rustup"
log_feature_summary \
    --feature "Rust Development Tools" \
    --tools "rust-analyzer,clippy,rustfmt,cargo-watch,cargo-audit,cargo-outdated,cargo-expand,cargo-release,cargo-deny,sccache,bacon,tokei,hyperfine,just,mdbook,taplo" \
    --paths "${CARGO_HOME},${RUSTUP_HOME}" \
    --env "CARGO_HOME,RUSTUP_HOME" \
    --commands "rust-analyzer,cargo-clippy,cargo-fmt,cargo-watch,cargo-audit,cargo-outdated,cargo-nextest,rust-lint-all,rust-security-check,rust-watch" \
    --next-steps "Run 'test-rust-dev' to check installed tools. Use 'cargo clippy' for linting, 'cargo fmt' for formatting, 'cargo watch' for hot reload, 'cargo nextest run' for fast tests."

# End logging
log_feature_end

echo ""
echo "Run 'test-rust-dev' to check installed tools"
echo "Run 'check-build-logs.sh rust-development-tools' to review installation logs"
