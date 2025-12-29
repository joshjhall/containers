#!/bin/bash
# Claude Code LSP Integrations
#
# Description:
#   Installs language server protocol servers for detected language runtimes.
#   These enhance Claude Code code intelligence capabilities.
#
# Requirements:
#   - INCLUDE_DEV_TOOLS=true (Claude Code CLI installed)
#   - INCLUDE_CLAUDE_INTEGRATIONS=true
#
# LSP Servers Installed:
#   - Python: python-lsp-server with black and ruff plugins
#   - Node/TypeScript: typescript-language-server
#   - R: languageserver
#
# Note: Go (gopls), Ruby (solargraph), and Rust (rust-analyzer) LSPs are
# already installed by their respective *-dev.sh scripts.

set -euo pipefail

# Source feature utilities
source /tmp/build-scripts/base/feature-header.sh

# ============================================================================
# Feature Start
# ============================================================================
log_feature_start "claude-lsp"

# ============================================================================
# Prerequisites Check
# ============================================================================

# Exit early if Claude CLI not installed (dev-tools wasn't enabled)
if [ ! -f "/usr/local/bin/claude" ]; then
    log_warning "Claude CLI not found at /usr/local/bin/claude"
    log_warning "Skipping LSP integrations - INCLUDE_DEV_TOOLS may not be enabled"
    log_feature_end
    exit 0
fi

log_message "Claude CLI detected - installing language server integrations"

# ============================================================================
# Language Detection Functions
# ============================================================================

is_python_installed() { [ -f "/usr/local/bin/python" ]; }
is_node_installed() { [ -f "/usr/local/bin/node" ]; }
is_r_installed() { [ -f "/usr/local/bin/R" ]; }

# Track what was installed
INSTALLED_LSPS=()

# ============================================================================
# Python LSP
# ============================================================================

if is_python_installed; then
    log_message "Python detected - installing Python LSP server with plugins"

    # Install python-lsp-server with formatting and linting plugins
    # - python-lsp-server: Core LSP implementation
    # - python-lsp-black: Black formatter integration
    # - python-lsp-ruff: Ruff linter integration (fast, replaces flake8/isort)
    log_command "Installing python-lsp-server with plugins" \
        pip install --no-cache-dir \
            python-lsp-server \
            python-lsp-black \
            python-lsp-ruff || {
        log_warning "Failed to install Python LSP - continuing without it"
    }

    # Verify installation
    if command -v pylsp &>/dev/null; then
        log_message "Python LSP installed successfully"
        INSTALLED_LSPS+=("pylsp")
    else
        log_warning "Python LSP installation could not be verified"
    fi
else
    log_message "Python not detected - skipping Python LSP"
fi

# ============================================================================
# TypeScript/JavaScript LSP
# ============================================================================

if is_node_installed; then
    log_message "Node.js detected - installing TypeScript language server"

    # Set up npm for global installs
    export NPM_CONFIG_PREFIX="/usr/local"

    # Install typescript-language-server
    # - typescript-language-server: LSP wrapper for TypeScript's tsserver
    # - typescript: Required peer dependency
    log_command "Installing typescript-language-server" \
        npm install -g --silent \
            typescript-language-server \
            typescript || {
        log_warning "Failed to install TypeScript LSP - continuing without it"
    }

    # Verify installation
    if command -v typescript-language-server &>/dev/null; then
        log_message "TypeScript LSP installed successfully"
        INSTALLED_LSPS+=("typescript-language-server")
    else
        log_warning "TypeScript LSP installation could not be verified"
    fi
else
    log_message "Node.js not detected - skipping TypeScript LSP"
fi

# ============================================================================
# R LSP
# ============================================================================

if is_r_installed; then
    log_message "R detected - installing R language server"

    # Install R languageserver package from CRAN
    log_command "Installing R languageserver" \
        Rscript -e "install.packages('languageserver', repos='https://cloud.r-project.org/', quiet=TRUE)" || {
        log_warning "Failed to install R LSP - continuing without it"
    }

    # Verify installation
    if Rscript -e "library(languageserver)" &>/dev/null; then
        log_message "R LSP installed successfully"
        INSTALLED_LSPS+=("languageserver")
    else
        log_warning "R LSP installation could not be verified"
    fi
else
    log_message "R not detected - skipping R LSP"
fi

# ============================================================================
# Summary
# ============================================================================

if [ ${#INSTALLED_LSPS[@]} -gt 0 ]; then
    log_message "Claude Code LSP integrations complete"
    log_message "Installed LSP servers: ${INSTALLED_LSPS[*]}"
else
    log_message "No additional LSP servers installed (languages may already have LSPs from *-dev scripts)"
fi

# Note existing LSPs from language dev scripts
log_message "Note: The following LSPs are installed by their respective *-dev scripts:"
log_message "  - Go: gopls (from golang-dev.sh)"
log_message "  - Ruby: solargraph (from ruby-dev.sh)"
log_message "  - Rust: rust-analyzer (from rustup)"

log_feature_end
