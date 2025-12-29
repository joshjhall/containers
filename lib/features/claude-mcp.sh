#!/bin/bash
# Claude Code MCP Server Installation
#
# Description:
#   Installs Model Context Protocol servers for enhanced Claude Code
#   capabilities. Provides filesystem access, GitHub, and GitLab integrations.
#
# Requirements:
#   - INCLUDE_DEV_TOOLS=true (Claude Code CLI installed)
#   - INCLUDE_MCP_SERVERS=true
#   - Node.js (auto-installed by Dockerfile when INCLUDE_MCP_SERVERS=true)
#
# MCP Servers Installed:
#   - @modelcontextprotocol/server-filesystem: Enhanced file operations
#   - @modelcontextprotocol/server-github: GitHub API integration
#   - @modelcontextprotocol/server-gitlab: GitLab API integration
#
# LSP Server Installed:
#   - bash-language-server: Shell script language server (grouped here since it needs Node)
#
# Configuration:
#   Creates ~/.claude/settings.json with MCP server configurations.
#   Tokens are read from environment variables at runtime:
#   - GITHUB_TOKEN: GitHub personal access token
#   - GITLAB_TOKEN: GitLab personal access token
#   - GITLAB_API_URL: GitLab API URL (defaults to https://gitlab.com/api/v4)

set -euo pipefail

# Source feature utilities
source /tmp/build-scripts/base/feature-header.sh

# ============================================================================
# Feature Start
# ============================================================================
log_feature_start "claude-mcp"

# ============================================================================
# Prerequisites Check
# ============================================================================

# Exit early if Claude CLI not installed (dev-tools wasn't enabled)
if [ ! -f "/usr/local/bin/claude" ]; then
    log_warning "Claude CLI not found at /usr/local/bin/claude"
    log_warning "Skipping MCP servers - INCLUDE_DEV_TOOLS may not be enabled"
    log_feature_end
    exit 0
fi

# Node.js should be guaranteed by Dockerfile conditional, but verify
if [ ! -f "/usr/local/bin/node" ]; then
    log_error "Node.js not found at /usr/local/bin/node"
    log_error "MCP servers require Node.js - this is a build configuration error"
    log_feature_end
    exit 1
fi

log_message "Claude CLI and Node.js detected - installing MCP servers"

# ============================================================================
# MCP Server Installation
# ============================================================================

# Set up npm for global installs
export NPM_CONFIG_PREFIX="/usr/local"

log_message "Installing MCP servers globally via npm..."

# Install all MCP servers
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

# ============================================================================
# Bash Language Server (grouped with MCPs since both require Node)
# ============================================================================
log_message "Installing bash-language-server for shell script IDE support..."

# bash-language-server provides LSP for bash/sh/zsh scripts
# Integrates with shellcheck for linting (if installed)
log_command "Installing bash-language-server" \
    npm install -g --silent bash-language-server || {
    log_warning "Failed to install bash-language-server"
}

# Verify installation
if command -v bash-language-server &>/dev/null; then
    log_message "bash-language-server installed successfully"
else
    log_warning "bash-language-server installation could not be verified"
fi

# ============================================================================
# First-Startup Script for MCP Configuration
# ============================================================================
# The MCP config needs to be created at runtime, not build time, because:
# - The home directory is often mounted as a volume
# - Build-time config would be hidden by the volume mount

log_message "Setting up MCP configuration first-startup script..."

log_command "Creating container startup directory" \
    mkdir -p /etc/container/first-startup

command cat > /etc/container/first-startup/30-claude-mcp-setup.sh << 'MCP_STARTUP_EOF'
#!/bin/bash
# Claude Code MCP Configuration Setup
# Uses `claude mcp add` CLI command for proper configuration
#
# Features:
# - Always includes filesystem MCP server
# - Detects GitHub vs GitLab from git remote origin
# - Auto-configures GitLab API URL for private instances
# - Idempotent: checks existing config before adding

set -euo pipefail

echo "=== Claude Code MCP Configuration ==="

# ============================================================================
# Prerequisites Check
# ============================================================================

# Verify claude CLI is available
if ! command -v claude &>/dev/null; then
    echo "Warning: Claude CLI not found in PATH"
    echo "MCP servers are installed but must be configured manually"
    exit 0
fi

# ============================================================================
# Git Remote Detection
# ============================================================================

detect_git_platform() {
    local remote_url=""

    # Try to get the git remote origin URL
    if command -v git &>/dev/null && git rev-parse --git-dir &>/dev/null 2>&1; then
        remote_url=$(git config --get remote.origin.url 2>/dev/null || true)
    fi

    if [ -z "$remote_url" ]; then
        echo "none"
        return
    fi

    # Normalize the URL to extract the host
    local host=""
    if [[ "$remote_url" =~ ^https?://([^/]+)/ ]]; then
        host="${BASH_REMATCH[1]}"
    elif [[ "$remote_url" =~ ^git@([^:]+): ]]; then
        host="${BASH_REMATCH[1]}"
    elif [[ "$remote_url" =~ ^ssh://[^@]+@([^/]+)/ ]]; then
        host="${BASH_REMATCH[1]}"
    fi

    if [ -z "$host" ]; then
        echo "none"
        return
    fi

    # Remove port if present
    host="${host%%:*}"

    # Detect platform
    if [[ "$host" == "github.com" ]]; then
        echo "github"
    elif [[ "$host" == "gitlab.com" ]] || [[ "$host" == *"gitlab"* ]]; then
        # gitlab.com or any host containing "gitlab" (private instances)
        echo "gitlab:$host"
    else
        # Unknown host - could be a private GitLab instance
        # Default to none, user can configure manually
        echo "unknown:$host"
    fi
}

# ============================================================================
# MCP Server Helper Functions
# ============================================================================

# Check if an MCP server is already configured
has_mcp_server() {
    local server_name="$1"
    claude mcp list 2>/dev/null | grep -q "^${server_name}:"
}

# Add an MCP server using claude CLI (idempotent)
add_mcp_server() {
    local server_name="$1"
    shift
    local args=("$@")

    if has_mcp_server "$server_name"; then
        echo "  - $server_name: already configured (skipping)"
        return 0
    fi

    if claude mcp add -s user -t stdio "$server_name" "${args[@]}" 2>/dev/null; then
        echo "  - $server_name: added"
    else
        echo "  - $server_name: failed to add"
        return 1
    fi
}

# ============================================================================
# Main Configuration Logic
# ============================================================================

# Detect git platform
platform_info=$(detect_git_platform)
platform="${platform_info%%:*}"
platform_host="${platform_info#*:}"

echo "Detected git platform: $platform_info"
echo ""
echo "Configuring MCP servers:"

# Always add filesystem MCP
add_mcp_server "filesystem" -- npx -y @modelcontextprotocol/server-filesystem /workspace

# Add platform-specific MCP
case "$platform" in
    github)
        # Note: Token is referenced via environment variable at runtime
        add_mcp_server "github" \
            -e 'GITHUB_PERSONAL_ACCESS_TOKEN=${GITHUB_TOKEN}' \
            -- npx -y @modelcontextprotocol/server-github
        echo ""
        echo "GitHub detected. Set GITHUB_TOKEN environment variable for API access."
        ;;
    gitlab)
        # GitLab with custom API URL for private instances
        add_mcp_server "gitlab" \
            -e 'GITLAB_PERSONAL_ACCESS_TOKEN=${GITLAB_TOKEN}' \
            -e "GITLAB_API_URL=https://${platform_host}/api/v4" \
            -- npx -y @modelcontextprotocol/server-gitlab
        echo ""
        echo "GitLab detected ($platform_host)."
        echo "Set GITLAB_TOKEN environment variable for API access."
        ;;
    unknown)
        echo ""
        echo "Unknown git host: $platform_host"
        echo "Configure MCP servers manually with: claude mcp add <name> -- <command>"
        ;;
    none)
        echo ""
        echo "No git remote detected."
        echo "Filesystem MCP is available. Add GitHub/GitLab MCP manually if needed."
        ;;
esac

echo ""
echo "MCP configuration complete. Run 'claude mcp list' to verify."
MCP_STARTUP_EOF

log_command "Setting MCP startup script permissions" \
    chmod +x /etc/container/first-startup/30-claude-mcp-setup.sh

# ============================================================================
# Verification
# ============================================================================

log_message "Verifying MCP server installations..."

VERIFIED_SERVERS=()

# Check each server
if npm list -g @modelcontextprotocol/server-filesystem &>/dev/null; then
    VERIFIED_SERVERS+=("filesystem")
fi

if npm list -g @modelcontextprotocol/server-github &>/dev/null; then
    VERIFIED_SERVERS+=("github")
fi

if npm list -g @modelcontextprotocol/server-gitlab &>/dev/null; then
    VERIFIED_SERVERS+=("gitlab")
fi

# ============================================================================
# Summary
# ============================================================================

if [ ${#VERIFIED_SERVERS[@]} -gt 0 ]; then
    log_message "MCP servers installed: ${VERIFIED_SERVERS[*]}"
else
    log_warning "No MCP servers could be verified"
fi

log_message ""
log_message "MCP configuration will be created on first container startup."
log_message "The startup script will:"
log_message "  - Always configure filesystem MCP server"
log_message "  - Detect GitHub/GitLab from git remote and configure accordingly"
log_message "  - Auto-detect GitLab API URL for private instances"
log_message "  - Be idempotent (safe to run multiple times)"
log_message ""

log_feature_end
