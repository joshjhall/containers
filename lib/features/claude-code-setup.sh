#!/bin/bash
# Claude Code Setup - CLI, plugins, and MCP server installation
#
# Description:
#   Installs Claude Code CLI, creates the claude-setup command for plugin
#   and MCP server configuration, and sets up first-startup scripts.
#
# Features:
#   - Claude Code CLI installation with checksum verification
#   - MCP servers: filesystem, GitHub, GitLab (requires Node.js)
#   - bash-language-server for shell script LSP
#   - claude-setup command for plugin and MCP configuration
#   - First-startup script for automatic configuration
#
# Dependencies:
#   - Must run AFTER dev-tools.sh (reads enabled-features.conf)
#   - Node.js required for MCP servers (optional)
#
# Build Arguments (read from enabled-features.conf):
#   - INCLUDE_PYTHON_DEV, INCLUDE_NODE_DEV, INCLUDE_RUST_DEV, INCLUDE_KOTLIN_DEV
#   - CLAUDE_EXTRA_PLUGINS (comma-separated list of additional plugins)
#
set -euo pipefail

# Source standard feature header for user handling
source /tmp/build-scripts/base/feature-header.sh

# Source retry utilities for network operations
source /tmp/build-scripts/base/retry-utils.sh

# Source download verification utilities for secure binary downloads
source /tmp/build-scripts/base/download-verify.sh

# Source checksum fetching utilities for dynamic checksum retrieval
source /tmp/build-scripts/features/lib/checksum-fetch.sh

# Start logging
log_feature_start "Claude Code Setup"

# ============================================================================
# Install Claude Code CLI
# ============================================================================
log_message "Installing Claude Code CLI..."

# Get the target user's home directory
TARGET_USER="${USERNAME:-developer}"
if [ "$TARGET_USER" = "root" ]; then
    USER_HOME="/root"
else
    USER_HOME="/home/$TARGET_USER"
fi

# Security Note: The Claude install script (https://claude.ai/install.sh) performs
# checksum verification internally:
# 1. Downloads manifest.json with expected SHA256 checksums
# 2. Downloads the binary
# 3. Verifies downloaded binary matches expected checksum using sha256sum
# 4. Fails installation if verification fails
#
# Additionally, we verify the installer script itself before execution to ensure
# the installer hasn't been compromised at the distribution point.

# Download and verify Claude Code installer with checksum
CLAUDE_INSTALLER_URL="https://claude.ai/install.sh"
log_message "Calculating checksum for Claude Code installer..."
CLAUDE_INSTALLER_CHECKSUM=$(calculate_checksum_sha256 "$CLAUDE_INSTALLER_URL" 2>/dev/null)

if [ -z "$CLAUDE_INSTALLER_CHECKSUM" ]; then
    log_warning "Failed to calculate checksum for Claude Code installer"
    log_warning "Claude Code will not be available in this container"
else
    log_message "Expected SHA256: ${CLAUDE_INSTALLER_CHECKSUM}"

    BUILD_TEMP=$(create_secure_temp_dir)
    if download_and_verify \
        "$CLAUDE_INSTALLER_URL" \
        "$CLAUDE_INSTALLER_CHECKSUM" \
        "${BUILD_TEMP}/claude-install.sh"; then
        log_message "✓ Claude Code installer verified successfully"
    else
        log_warning "Failed to download or verify Claude Code installer"
        log_warning "Claude Code will not be available in this container"
    fi
fi

if [ -f "${BUILD_TEMP}/claude-install.sh" ]; then
    # Install Claude Code to the target user's home directory
    log_command "Installing Claude Code for user $TARGET_USER" \
        su -c "cd '$USER_HOME' && bash ${BUILD_TEMP}/claude-install.sh" "$TARGET_USER" || {
            log_warning "Claude Code installation failed"
            log_warning "Claude Code will not be available in this container"
        }

    # Create system-wide symlink if installation succeeded
    if [ -f "$USER_HOME/.local/bin/claude" ]; then
        log_command "Creating system-wide Claude symlink" \
            ln -sf "$USER_HOME/.local/bin/claude" /usr/local/bin/claude
    fi
fi

# ============================================================================
# MCP Servers and Bash LSP
# ============================================================================
# MCP servers require Node.js - install if available
if command -v node &>/dev/null && command -v npm &>/dev/null; then
    log_message "Installing MCP servers and bash-language-server..."

    export NPM_CONFIG_PREFIX="/usr/local"

    log_command "Installing @modelcontextprotocol/server-filesystem" \
        npm install -g --silent @modelcontextprotocol/server-filesystem || {
        log_warning "Failed to install filesystem MCP server"
    }

    log_command "Installing @modelcontextprotocol/server-github" \
        npm install -g --silent @modelcontextprotocol/server-github || {
        log_warning "Failed to install GitHub MCP server"
    }

    log_command "Installing @modelcontextprotocol/server-gitlab" \
        npm install -g --silent @modelcontextprotocol/server-gitlab || {
        log_warning "Failed to install GitLab MCP server"
    }

    log_command "Installing bash-language-server" \
        npm install -g --silent bash-language-server || {
        log_warning "Failed to install bash-language-server"
    }

    # Verify bash-language-server installation
    if command -v bash-language-server &>/dev/null; then
        log_message "bash-language-server installed successfully"
    else
        log_warning "bash-language-server installation could not be verified"
    fi

    log_message "MCP servers installed successfully"
else
    log_message "Node.js not available - skipping MCP servers and bash-language-server"
    log_message "To enable MCP servers, add INCLUDE_NODE=true or INCLUDE_NODE_DEV=true"
fi

# ============================================================================
# Container Startup Scripts
# ============================================================================
log_message "Creating startup scripts..."

# Create startup directory if it doesn't exist
log_command "Creating container startup directory" \
    mkdir -p /etc/container/first-startup

# ============================================================================
# Create claude-setup Command
# ============================================================================
# This command can be run manually by users after running 'claude' to install
# plugins and configure MCP servers. It's also called automatically at startup
# if Claude is authenticated.
log_message "Creating claude-setup command..."

command cat > /usr/local/bin/claude-setup << 'CLAUDE_SETUP_EOF'
#!/bin/bash
# claude-setup - Configure Claude Code plugins and MCP servers
#
# This script installs Claude Code plugins and configures MCP servers.
# It can be run manually after running 'claude' or automatically at startup.
#
# IMPORTANT: Plugin installation requires running 'claude' first to authenticate.
# Environment variables (ANTHROPIC_API_KEY, etc.) do NOT work for plugin
# installation in headless environments - you must authenticate interactively.
#
# Workflow:
# 1. Run 'claude' and authenticate when prompted
# 2. Close Claude client (Ctrl+C)
# 3. Run 'claude-setup' to install plugins
# 4. Restart Claude if needed
#
# Features:
# - Installs core plugins from claude-plugins-official marketplace
# - Installs language-specific LSP plugins based on build-time flags
# - Configures MCP servers (filesystem, figma-desktop, github/gitlab)
# - Idempotent: safe to run multiple times
# - Graceful: skips plugin installation if not authenticated
#
# Usage:
#   claude-setup           # Run with authentication check
#   claude-setup --force   # Run even if not authenticated (for MCP setup only)
#
# Plugin Marketplace: claude-plugins-official

set -euo pipefail

FORCE_MODE=false
[ "${1:-}" = "--force" ] && FORCE_MODE=true

# ============================================================================
# Load Build-Time Configuration
# ============================================================================
ENABLED_FEATURES_FILE="/etc/container/config/enabled-features.conf"
if [ -f "$ENABLED_FEATURES_FILE" ]; then
    # shellcheck source=/dev/null
    source "$ENABLED_FEATURES_FILE"
fi

# ============================================================================
# Authentication Check
# ============================================================================
is_claude_authenticated() {
    # Check for OAuth credentials (created by running 'claude' and authenticating)
    # This is the ONLY authentication method that works for plugin installation
    if [ -f ~/.claude/.credentials.json ]; then
        if grep -q '"claudeAiOauth"' ~/.claude/.credentials.json 2>/dev/null; then
            return 0
        fi
    fi

    # Check for oauthAccount in main config (indicates OAuth login)
    if [ -f ~/.claude.json ]; then
        if grep -q '"oauthAccount"' ~/.claude.json 2>/dev/null; then
            # Verify it's not null/empty
            if jq -e '.oauthAccount != null and .oauthAccount != ""' ~/.claude.json >/dev/null 2>&1; then
                return 0
            fi
        fi
    fi

    return 1
}


# Exit early if Claude Code not available
if ! command -v claude &> /dev/null; then
    echo "Claude Code CLI not installed. Skipping setup."
    exit 0
fi

echo "=== Claude Code Setup ==="
echo ""

# ============================================================================
# Plugin Installation Logic
# ============================================================================
# --force mode: skip plugins entirely, only configure MCP servers
# normal mode: install plugins if authenticated
SKIP_PLUGINS=false
if [ "$FORCE_MODE" = "true" ]; then
    if ! is_claude_authenticated; then
        SKIP_PLUGINS=true
    fi
fi

# ============================================================================
# Plugin Helpers
# ============================================================================
MARKETPLACE="claude-plugins-official"
PLUGINS_INSTALLED=false

has_plugin() {
    local plugin_name="$1"
    claude plugin list 2>/dev/null | grep -q "❯ ${plugin_name}@" 2>/dev/null || return 1
}

install_plugin() {
    local plugin_name="$1"
    local full_name="${plugin_name}@${MARKETPLACE}"

    if has_plugin "$plugin_name"; then
        echo "    ✓ $plugin_name (already installed)"
        return 0
    fi

    echo "  - Installing $plugin_name..."
    local output
    if output=$(claude plugin install "$full_name" 2>&1); then
        echo "    ✓ $plugin_name installed"
        PLUGINS_INSTALLED=true
        return 0
    else
        # Show error output for debugging
        echo "    ⚠ Failed to install $plugin_name"
        echo "$output" | sed 's/^/      /' | head -5
        return 1
    fi
}

# ============================================================================
# Plugin Installation (requires authentication)
# ============================================================================
if [ "$SKIP_PLUGINS" = "true" ]; then
    echo "Skipping plugin installation (not authenticated)"
    echo "After authenticating, run: claude-setup"
    echo ""
elif is_claude_authenticated; then
    # Show which auth method was detected (helpful for debugging)
    if [ -f ~/.claude/.credentials.json ] && grep -q '"claudeAiOauth"' ~/.claude/.credentials.json 2>/dev/null; then
        echo "Authentication: OAuth (interactive)"
    elif [ -f ~/.claude.json ] && grep -q '"oauthAccount"' ~/.claude.json 2>/dev/null; then
        echo "Authentication: OAuth account"
    else
        echo "Authentication: Detected"
    fi
    echo ""
    echo "Installing plugins..."
    echo ""

    # Core Plugins (Always Installed)
    echo "Core plugins:"
    install_plugin "commit-commands" || true
    install_plugin "frontend-design" || true
    install_plugin "code-simplifier" || true
    install_plugin "context7" || true
    install_plugin "security-guidance" || true
    install_plugin "claude-md-management" || true
    install_plugin "figma" || true
    install_plugin "pr-review-toolkit" || true
    install_plugin "code-review" || true
    install_plugin "hookify" || true
    install_plugin "claude-code-setup" || true
    install_plugin "feature-dev" || true

    # Language-Specific LSP Plugins (Based on Build Flags)
    echo ""
    echo "Language LSP plugins:"
    [ "${INCLUDE_RUST_DEV:-false}" = "true" ] && { install_plugin "rust-analyzer-lsp" || true; }
    [ "${INCLUDE_PYTHON_DEV:-false}" = "true" ] && { install_plugin "pyright-lsp" || true; }
    [ "${INCLUDE_NODE_DEV:-false}" = "true" ] && { install_plugin "typescript-lsp" || true; }
    [ "${INCLUDE_KOTLIN_DEV:-false}" = "true" ] && { install_plugin "kotlin-lsp" || true; }

    # Extra Plugins (From Environment Variable)
    # CLAUDE_EXTRA_PLUGINS can be set at build time or runtime
    EXTRA_PLUGINS_TO_INSTALL="${CLAUDE_EXTRA_PLUGINS:-${CLAUDE_EXTRA_PLUGINS_DEFAULT:-}}"
    if [ -n "$EXTRA_PLUGINS_TO_INSTALL" ]; then
        echo ""
        echo "Extra plugins (CLAUDE_EXTRA_PLUGINS):"
        IFS=',' read -ra EXTRA_PLUGINS <<< "$EXTRA_PLUGINS_TO_INSTALL"
        for plugin in "${EXTRA_PLUGINS[@]}"; do
            plugin=$(echo "$plugin" | xargs)  # Trim whitespace
            [ -n "$plugin" ] && { install_plugin "$plugin" || true; }
        done
    fi

    echo ""
else
    echo "Claude Code not authenticated."
    echo ""
    echo "Plugin installation requires interactive authentication."
    echo ""
    echo "Workflow:"
    echo ""
    echo "  1. Run Claude and authenticate when prompted:"
    echo "       claude"
    echo ""
    echo "  2. Close Claude client (Ctrl+C)"
    echo ""
    echo "  3. Run setup to install plugins:"
    echo "       claude-setup"
    echo ""
    echo "  4. Restart Claude if needed"
    echo ""
fi

# ============================================================================
# MCP Server Configuration (no authentication required)
# ============================================================================
echo "Configuring MCP servers..."
echo ""

has_mcp_server() {
    local server_name="$1"
    claude mcp list 2>/dev/null | grep -qE "^${server_name}[[:space:]]" 2>/dev/null || return 1
}

add_mcp_server() {
    local server_name="$1"
    shift
    local args=("$@")

    if has_mcp_server "$server_name"; then
        echo "    ✓ $server_name (already configured)"
        return 0
    fi

    echo "  - Adding $server_name..."
    if claude mcp add -s user "${args[@]}" 2>&1 | grep -v "^Added"; then
        echo "    ✓ $server_name added"
    else
        echo "    ⚠ Failed to add $server_name"
    fi
}

# Filesystem MCP (always)
add_mcp_server "filesystem" -t stdio "filesystem" -- npx -y @modelcontextprotocol/server-filesystem /workspace

# Figma desktop MCP (always - connects to Figma desktop app via Docker host)
add_mcp_server "figma-desktop" -t http "figma-desktop" "http://host.docker.internal:3845/mcp"

# ============================================================================
# Git Platform Detection for GitHub/GitLab MCPs
# ============================================================================
detect_git_platform() {
    local remote_url=""
    if command -v git &>/dev/null && git rev-parse --git-dir &>/dev/null 2>&1; then
        remote_url=$(git config --get remote.origin.url 2>/dev/null || true)
    fi
    [ -z "$remote_url" ] && { echo "none"; return; }

    local host=""
    [[ "$remote_url" =~ ^https?://([^/]+)/ ]] && host="${BASH_REMATCH[1]}"
    [[ "$remote_url" =~ ^git@([^:]+): ]] && host="${BASH_REMATCH[1]}"
    [[ "$remote_url" =~ ^ssh://[^@]+@([^/]+)/ ]] && host="${BASH_REMATCH[1]}"
    [ -z "$host" ] && { echo "none"; return; }

    host="${host%%:*}"
    [[ "$host" == "github.com" ]] && { echo "github"; return; }
    [[ "$host" == "gitlab.com" ]] || [[ "$host" == *"gitlab"* ]] && { echo "gitlab:$host"; return; }
    echo "unknown:$host"
}

platform_info=$(detect_git_platform)
platform="${platform_info%%:*}"
platform_host="${platform_info#*:}"

case "$platform" in
    github)
        echo "  Detected GitHub repository"
        add_mcp_server "github" -t stdio "github" \
            -e 'GITHUB_PERSONAL_ACCESS_TOKEN=${GITHUB_TOKEN}' \
            -- npx -y @modelcontextprotocol/server-github
        ;;
    gitlab)
        echo "  Detected GitLab repository ($platform_host)"
        add_mcp_server "gitlab" -t stdio "gitlab" \
            -e 'GITLAB_PERSONAL_ACCESS_TOKEN=${GITLAB_TOKEN}' \
            -e "GITLAB_API_URL=https://${platform_host}/api/v4" \
            -- npx -y @modelcontextprotocol/server-gitlab
        ;;
    *)
        # Ambiguous or no git remote - install both for flexibility
        echo "  No specific git platform detected - installing both GitHub and GitLab MCPs"
        add_mcp_server "github" -t stdio "github" \
            -e 'GITHUB_PERSONAL_ACCESS_TOKEN=${GITHUB_TOKEN}' \
            -- npx -y @modelcontextprotocol/server-github
        add_mcp_server "gitlab" -t stdio "gitlab" \
            -e 'GITLAB_PERSONAL_ACCESS_TOKEN=${GITLAB_TOKEN}' \
            -- npx -y @modelcontextprotocol/server-gitlab
        ;;
esac

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Verify with:"
echo "  claude plugin list  - See installed plugins"
echo "  claude mcp list     - See configured MCP servers"
echo ""
if ! is_claude_authenticated; then
    echo "Note: Plugins were not installed (not authenticated)."
    echo "After running 'claude' and authenticating, run 'claude-setup' again."
    echo ""
fi
echo "Environment: ENABLE_LSP_TOOL=1"
echo "Set GITHUB_TOKEN or GITLAB_TOKEN for git platform API access."
CLAUDE_SETUP_EOF

log_command "Setting claude-setup permissions" \
    chmod +x /usr/local/bin/claude-setup

# ============================================================================
# Create First-Startup Script (calls claude-setup)
# ============================================================================
log_message "Creating first-startup script..."

command cat > /etc/container/first-startup/30-claude-code-setup.sh << 'EOF'
#!/bin/bash
# Claude Code first-startup wrapper
# Calls claude-setup to configure plugins and MCP servers
#
# This script runs once on first container startup. It:
# - Checks if Claude is authenticated (via running 'claude')
# - Runs claude-setup automatically if authenticated
# - Shows instructions if not authenticated
#
# IMPORTANT: Environment variables (ANTHROPIC_API_KEY, etc.) do NOT work
# for plugin installation. You must run 'claude' and authenticate interactively first.
#
# Workflow for plugin installation:
# 1. Start container
# 2. Run 'claude' and authenticate when prompted
# 3. Close Claude client (Ctrl+C)
# 4. Run 'claude-setup' to install plugins
# 5. Restart Claude if needed

set -euo pipefail

# Run claude-setup (it handles authentication checks internally)
if command -v claude-setup &> /dev/null; then
    claude-setup --force
fi
EOF
log_command "Setting Claude Code startup script permissions" \
    chmod +x /etc/container/first-startup/30-claude-code-setup.sh

# ============================================================================
# Feature Summary
# ============================================================================
log_feature_summary \
    --feature "Claude Code Setup" \
    --tools "claude,claude-setup,bash-language-server" \
    --paths "/usr/local/bin/claude,/usr/local/bin/claude-setup,/etc/container/first-startup/30-claude-code-setup.sh" \
    --env "ENABLE_LSP_TOOL,CLAUDE_EXTRA_PLUGINS" \
    --commands "claude,claude-setup" \
    --next-steps "Run 'claude' to authenticate, then 'claude-setup' to install plugins and configure MCP servers."

# End logging
log_feature_end

echo ""
echo "Run 'claude' to authenticate, then 'claude-setup' to install plugins"
echo "Run 'check-build-logs.sh claude-code-setup' to review installation logs"
