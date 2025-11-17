#!/bin/bash
# Setup comprehensive PATH configuration using /etc/bashrc.d
# This ensures paths work in both interactive and non-interactive shells

set -euo pipefail

echo "=== Setting up comprehensive PATH configuration ==="

# Ensure /etc/bashrc.d exists
mkdir -p /etc/bashrc.d

# Create comprehensive PATH setup that handles all installed tools
command cat > /etc/bashrc.d/10-tool-paths.sh << 'EOF'
# Comprehensive PATH setup for all installed tools

# Source base utilities for secure PATH management
if [ -f /opt/container-runtime/base/logging.sh ]; then
    source /opt/container-runtime/base/logging.sh
fi
if [ -f /opt/container-runtime/base/path-utils.sh ]; then
    source /opt/container-runtime/base/path-utils.sh
fi

# Security: Safe eval for tool initialization
safe_eval() {
    local output
    if ! output=$("$@" 2>/dev/null); then
        return 1
    fi
    # Use 'command grep' to bypass any aliases (e.g., grep='rg' from dev-tools)
    if echo "$output" | command grep -qE '(rm -rf|curl.*bash|wget.*bash|;\s*rm|\$\(.*rm)|exec\s+[^$]|/bin/sh.*-c|bash.*-c.*http)'; then
        echo "WARNING: Suspicious output detected, skipping initialization of: $*" >&2
        return 1
    fi
    eval "$output"
}

# Base paths
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"

# User local bin with security validation
if command -v safe_add_to_path >/dev/null 2>&1; then
    safe_add_to_path "$HOME/.local/bin" 2>/dev/null || export PATH="$HOME/.local/bin:$PATH"
else
    export PATH="$HOME/.local/bin:$PATH"
fi

# Python paths are handled by the Python feature script

# Ruby (rbenv)
if [ -d /cache/rbenv ]; then
    export RBENV_ROOT="/cache/rbenv"
elif [ -d "$HOME/.rbenv" ]; then
    export RBENV_ROOT="$HOME/.rbenv"
fi
if [ -n "${RBENV_ROOT:-}" ]; then
    if command -v safe_add_to_path >/dev/null 2>&1; then
        safe_add_to_path "$RBENV_ROOT/bin" 2>/dev/null || export PATH="$RBENV_ROOT/bin:$PATH"
    else
        export PATH="$RBENV_ROOT/bin:$PATH"
    fi
    safe_eval rbenv init -
fi

# Go
if [ -d /usr/local/go ]; then
    if command -v safe_add_to_path >/dev/null 2>&1; then
        safe_add_to_path "/usr/local/go/bin" 2>/dev/null || export PATH="/usr/local/go/bin:$PATH"
    else
        export PATH="/usr/local/go/bin:$PATH"
    fi
fi
if [ -d /cache/go ]; then
    export GOPATH="/cache/go"
elif [ -d "$HOME/go" ]; then
    export GOPATH="$HOME/go"
fi
if [ -n "${GOPATH:-}" ]; then
    if command -v safe_add_to_path >/dev/null 2>&1; then
        safe_add_to_path "$GOPATH/bin" 2>/dev/null || export PATH="$GOPATH/bin:$PATH"
    else
        export PATH="$GOPATH/bin:$PATH"
    fi
fi

# Rust
if [ -d /cache/cargo ]; then
    export CARGO_HOME="/cache/cargo"
    export RUSTUP_HOME="/cache/rustup"
elif [ -d "$HOME/.cargo" ]; then
    export CARGO_HOME="$HOME/.cargo"
    export RUSTUP_HOME="$HOME/.rustup"
fi
if [ -n "${CARGO_HOME:-}" ]; then
    if command -v safe_add_to_path >/dev/null 2>&1; then
        safe_add_to_path "$CARGO_HOME/bin" 2>/dev/null || export PATH="$CARGO_HOME/bin:$PATH"
    else
        export PATH="$CARGO_HOME/bin:$PATH"
    fi
fi

# Node.js global packages
if [ -d /cache/npm-global ]; then
    if command -v safe_add_to_path >/dev/null 2>&1; then
        safe_add_to_path "/cache/npm-global/bin" 2>/dev/null || export PATH="/cache/npm-global/bin:$PATH"
    else
        export PATH="/cache/npm-global/bin:$PATH"
    fi
elif [ -d "$HOME/.npm-global" ]; then
    if command -v safe_add_to_path >/dev/null 2>&1; then
        safe_add_to_path "$HOME/.npm-global/bin" 2>/dev/null || export PATH="$HOME/.npm-global/bin:$PATH"
    else
        export PATH="$HOME/.npm-global/bin:$PATH"
    fi
fi

# pipx
if [ -d /opt/pipx/bin ]; then
    if command -v safe_add_to_path >/dev/null 2>&1; then
        safe_add_to_path "/opt/pipx/bin" 2>/dev/null || export PATH="/opt/pipx/bin:$PATH"
    else
        export PATH="/opt/pipx/bin:$PATH"
    fi
fi

# Mojo
if [ -d "$HOME/.modular/bin" ]; then
    if command -v safe_add_to_path >/dev/null 2>&1; then
        safe_add_to_path "$HOME/.modular/bin" 2>/dev/null || export PATH="$HOME/.modular/bin:$PATH"
    else
        export PATH="$HOME/.modular/bin:$PATH"
    fi
fi

# Krew (kubectl plugins)
if [ -d "$HOME/.krew/bin" ]; then
    if command -v safe_add_to_path >/dev/null 2>&1; then
        safe_add_to_path "$HOME/.krew/bin" 2>/dev/null || export PATH="$HOME/.krew/bin:$PATH"
    else
        export PATH="$HOME/.krew/bin:$PATH"
    fi
fi

# fzf
if [ -d /opt/fzf/bin ]; then
    if command -v safe_add_to_path >/dev/null 2>&1; then
        safe_add_to_path "/opt/fzf/bin" 2>/dev/null || export PATH="/opt/fzf/bin:$PATH"
    else
        export PATH="/opt/fzf/bin:$PATH"
    fi
fi
EOF

# Make it executable
chmod +x /etc/bashrc.d/10-tool-paths.sh

# Also update /etc/environment with basic PATH for system-wide availability
# This provides a fallback for programs that don't use bash
{
    echo "# Basic system PATH - enhanced by /etc/bashrc.d scripts"
    echo 'PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"'
} > /etc/environment

echo "=== PATH setup complete ==="
echo "Paths configured in:"
echo "  - /etc/environment (basic system PATH)"
echo "  - /etc/bashrc.d/10-tool-paths.sh (comprehensive tool paths)"
echo "These will be available in both interactive and non-interactive shells."