#!/bin/bash
# Setup /etc/bashrc.d directory structure for modular shell configuration
# This enables both interactive and non-interactive shells to have consistent environments

set -euo pipefail

# Source bashrc helpers if available
if [ -f /tmp/build-scripts/base/bashrc-helpers.sh ]; then
    source /tmp/build-scripts/base/bashrc-helpers.sh
fi

echo "=== Setting up /etc/bashrc.d structure ==="

# Create the directory
mkdir -p /etc/bashrc.d

# Add sourcing to /etc/bash.bashrc for interactive shells
if ! grep -q "/etc/bashrc.d" /etc/bash.bashrc 2>/dev/null; then
    command cat >> /etc/bash.bashrc << 'EOF'

# Source all scripts in /etc/bashrc.d
if [ -d /etc/bashrc.d ]; then
    for f in /etc/bashrc.d/*.sh; do
        # Only source files that are both readable and executable (security best practice)
        [ -r "$f" ] && [ -x "$f" ] && . "$f"
    done
fi
EOF
fi

# Create /etc/bash_env for non-interactive shells
# This file sources only the non-interactive safe parts
command cat > /etc/bash_env << 'EOF'
#!/bin/bash
# Environment setup for non-interactive bash shells
# This file is sourced when BASH_ENV is set

# Source all scripts in /etc/bashrc.d
# These scripts should be written to work in both interactive and non-interactive contexts
if [ -d /etc/bashrc.d ]; then
    for f in /etc/bashrc.d/*.sh; do
        # Only source files that are both readable and executable (security best practice)
        [ -r "$f" ] && [ -x "$f" ] && . "$f" 2>/dev/null || true
    done
fi
EOF

chmod +x /etc/bash_env

# Create initial PATH setup that will be enhanced by features
if command -v write_bashrc_content &>/dev/null; then
    write_bashrc_content /etc/bashrc.d/00-base-paths.sh "base PATH setup" << 'BASE_PATHS_EOF'
# Base PATH setup
# This is sourced by both interactive and non-interactive shells

# Start with clean system paths
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Add user's local bin if it exists
if [ -d "$HOME/.local/bin" ]; then
    export PATH="$HOME/.local/bin:$PATH"
fi

# Features will append to PATH by creating additional files in /etc/bashrc.d/
BASE_PATHS_EOF
else
    # Fallback if bashrc-helpers.sh isn't available
    command cat > /etc/bashrc.d/00-base-paths.sh << 'BASE_PATHS_EOF'
# Base PATH setup
# This is sourced by both interactive and non-interactive shells

# Start with clean system paths
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Add user's local bin if it exists
if [ -d "$HOME/.local/bin" ]; then
    export PATH="$HOME/.local/bin:$PATH"
fi

# Features will append to PATH by creating additional files in /etc/bashrc.d/
BASE_PATHS_EOF
fi

chmod +x /etc/bashrc.d/00-base-paths.sh

echo "=== /etc/bashrc.d structure setup complete ==="
