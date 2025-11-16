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

# User local bin
export PATH="$HOME/.local/bin:$PATH"

# Python paths are handled by the Python feature script

# Ruby (rbenv)
if [ -d /cache/rbenv ]; then
    export RBENV_ROOT="/cache/rbenv"
elif [ -d "$HOME/.rbenv" ]; then
    export RBENV_ROOT="$HOME/.rbenv"
fi
if [ -n "${RBENV_ROOT:-}" ]; then
    export PATH="$RBENV_ROOT/bin:$PATH"
    safe_eval rbenv init -
fi

# Go
if [ -d /usr/local/go ]; then
    export PATH="/usr/local/go/bin:$PATH"
fi
if [ -d /cache/go ]; then
    export GOPATH="/cache/go"
elif [ -d "$HOME/go" ]; then
    export GOPATH="$HOME/go"
fi
if [ -n "${GOPATH:-}" ]; then
    export PATH="$GOPATH/bin:$PATH"
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
    export PATH="$CARGO_HOME/bin:$PATH"
fi

# Node.js global packages
if [ -d /cache/npm-global ]; then
    export PATH="/cache/npm-global/bin:$PATH"
elif [ -d "$HOME/.npm-global" ]; then
    export PATH="$HOME/.npm-global/bin:$PATH"
fi

# pipx
if [ -d /opt/pipx/bin ]; then
    export PATH="/opt/pipx/bin:$PATH"
fi

# Mojo
if [ -d "$HOME/.modular/bin" ]; then
    export PATH="$HOME/.modular/bin:$PATH"
fi

# Krew (kubectl plugins)
if [ -d "$HOME/.krew/bin" ]; then
    export PATH="$HOME/.krew/bin:$PATH"
fi

# fzf
if [ -d /opt/fzf/bin ]; then
    export PATH="/opt/fzf/bin:$PATH"
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