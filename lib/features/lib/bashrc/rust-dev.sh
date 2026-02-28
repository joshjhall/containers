# shellcheck disable=SC2164
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

# Cargo sweep aliases
alias sweep='cargo-sweep sweep --time 14'
alias sweep-all='command find "${WORKING_DIR:-/workspace}" -name "Cargo.toml" -exec dirname {} \; | xargs -I{} cargo-sweep sweep --time 14 {}'

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


# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
