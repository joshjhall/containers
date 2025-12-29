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
# MCP Configuration
# ============================================================================

log_message "Setting up Claude Code MCP configuration..."

# Get target user's home directory
TARGET_USER="${USERNAME:-developer}"
if [ "$TARGET_USER" = "root" ]; then
    USER_HOME="/root"
else
    USER_HOME="/home/$TARGET_USER"
fi

CLAUDE_CONFIG_DIR="${USER_HOME}/.claude"

# Create Claude config directory
log_command "Creating Claude config directory" \
    mkdir -p "$CLAUDE_CONFIG_DIR"

# Only create settings.json if it doesn't exist (don't overwrite user config)
if [ ! -f "${CLAUDE_CONFIG_DIR}/settings.json" ]; then
    log_message "Creating default MCP configuration..."

    cat > "${CLAUDE_CONFIG_DIR}/settings.json" << 'SETTINGS_EOF'
{
  "mcpServers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/workspace"],
      "description": "File system access for Claude Code"
    },
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": {
        "GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_TOKEN}"
      },
      "description": "GitHub API integration"
    },
    "gitlab": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-gitlab"],
      "env": {
        "GITLAB_PERSONAL_ACCESS_TOKEN": "${GITLAB_TOKEN}",
        "GITLAB_API_URL": "${GITLAB_API_URL:-https://gitlab.com/api/v4}"
      },
      "description": "GitLab API integration"
    }
  }
}
SETTINGS_EOF

    # Set proper ownership
    log_command "Setting config ownership" \
        chown -R "${TARGET_USER}:${TARGET_USER}" "$CLAUDE_CONFIG_DIR"

    log_message "MCP configuration created at ${CLAUDE_CONFIG_DIR}/settings.json"
else
    log_message "Existing settings.json found - preserving user configuration"
fi

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
log_message "To use GitHub/GitLab MCP servers, set environment variables:"
log_message "  - GITHUB_TOKEN: Your GitHub personal access token"
log_message "  - GITLAB_TOKEN: Your GitLab personal access token"
log_message "  - GITLAB_API_URL: GitLab API URL (optional, defaults to gitlab.com)"
log_message ""

log_feature_end
