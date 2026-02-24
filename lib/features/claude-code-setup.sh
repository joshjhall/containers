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
source /tmp/build-scripts/base/checksum-fetch.sh

# Start logging
log_feature_start "Claude Code Setup"

# ============================================================================
# Install Claude Code CLI
# ============================================================================
log_message "Installing Claude Code CLI..."

# Claude Code release channel (stable or latest)
CLAUDE_CHANNEL="${CLAUDE_CHANNEL:-latest}"
case "$CLAUDE_CHANNEL" in
    latest|stable) ;;
    *) log_error "Invalid CLAUDE_CHANNEL: '$CLAUDE_CHANNEL' (must be 'latest' or 'stable')"
       exit 1 ;;
esac
log_message "Using Claude Code channel: ${CLAUDE_CHANNEL}"

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
    # Pass the channel (stable or latest) to the installer
    log_command "Installing Claude Code for user $TARGET_USER (channel: ${CLAUDE_CHANNEL})" \
        su -c "cd '$USER_HOME' && bash ${BUILD_TEMP}/claude-install.sh ${CLAUDE_CHANNEL}" "$TARGET_USER" || {
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

    # Install extra MCP server packages from CLAUDE_EXTRA_MCPS
    EXTRA_MCPS_TO_INSTALL="${CLAUDE_EXTRA_MCPS:-}"
    if [ -n "$EXTRA_MCPS_TO_INSTALL" ]; then
        log_message "Installing extra MCP server packages..."
        source /tmp/build-scripts/features/mcp-registry.sh

        IFS=',' read -ra EXTRA_MCP_LIST <<< "$EXTRA_MCPS_TO_INSTALL"
        for mcp_name in "${EXTRA_MCP_LIST[@]}"; do
            mcp_name=$(echo "$mcp_name" | xargs)  # Trim whitespace
            [ -z "$mcp_name" ] && continue

            if ! mcp_registry_is_registered "$mcp_name"; then
                log_message "Unknown MCP server '$mcp_name' - will be resolved at runtime via npx"
                continue
            fi

            pkg_type=$(mcp_registry_get_package_type "$mcp_name" 2>/dev/null || echo "npm")
            if [ "$pkg_type" = "npm" ]; then
                npm_package=$(mcp_registry_get_npm_package "$mcp_name")
                log_command "Installing $npm_package" \
                    npm install -g --silent "$npm_package" || {
                    log_warning "Failed to install $npm_package"
                }
            elif [ "$pkg_type" = "uvx" ]; then
                # uvx-type packages need uv installed (provides uvx command)
                if ! command -v uvx &>/dev/null; then
                    if command -v pip &>/dev/null; then
                        log_command "Installing uv (provides uvx for $mcp_name)" \
                            pip install --quiet uv || {
                            log_warning "Failed to install uv - $mcp_name may not work at runtime"
                        }
                    elif command -v pip3 &>/dev/null; then
                        log_command "Installing uv (provides uvx for $mcp_name)" \
                            pip3 install --quiet uv || {
                            log_warning "Failed to install uv - $mcp_name may not work at runtime"
                        }
                    else
                        log_warning "pip not available - cannot install uv for $mcp_name"
                        log_warning "Add INCLUDE_PYTHON=true to enable uvx-based MCP servers"
                    fi
                fi
            fi
        done
    fi

    # Copy MCP registry to runtime config for use by claude-setup
    mkdir -p /etc/container/config
    log_command "Copying MCP registry to runtime config" \
        cp /tmp/build-scripts/features/mcp-registry.sh /etc/container/config/mcp-registry.sh
    log_command "Setting MCP registry permissions" \
        chmod 644 /etc/container/config/mcp-registry.sh

    log_message "MCP servers installed successfully"
else
    log_message "Node.js not available - skipping MCP servers and bash-language-server"
    log_message "To enable MCP servers, add INCLUDE_NODE=true or INCLUDE_NODE_DEV=true"
fi

# ============================================================================
# Stage Skill and Agent Templates for Runtime Installation
# ============================================================================
log_message "Staging skill and agent templates for runtime installation..."

if [ -d /tmp/build-scripts/features/templates/claude ]; then
    mkdir -p /etc/container/config/claude-templates
    cp -r /tmp/build-scripts/features/templates/claude/* /etc/container/config/claude-templates/
    chmod -R 644 /etc/container/config/claude-templates/
    find /etc/container/config/claude-templates -type d -exec chmod 755 {} \;
    log_message "Skill and agent templates staged to /etc/container/config/claude-templates/"
else
    log_warning "No skill/agent templates found at /tmp/build-scripts/features/templates/claude"
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
install -m 755 /tmp/build-scripts/features/lib/claude/claude-setup \
    /usr/local/bin/claude-setup

# ============================================================================
# Create First-Startup Script (calls claude-setup)
# ============================================================================
log_message "Creating first-startup script..."
install -m 755 /tmp/build-scripts/features/lib/claude/30-first-startup.sh \
    /etc/container/first-startup/30-claude-code-setup.sh

# ============================================================================
# Auto-Setup Watcher (Detects authentication and runs claude-setup)
# ============================================================================
log_message "Creating authentication watcher scripts..."
install -m 755 /tmp/build-scripts/features/lib/claude/claude-auth-watcher \
    /usr/local/bin/claude-auth-watcher

# Create startup directory if it doesn't exist
log_command "Creating container startup directory" \
    mkdir -p /etc/container/startup

# Install startup script that spawns the watcher in the background
install -m 755 /tmp/build-scripts/features/lib/claude/35-auth-watcher-startup.sh \
    /etc/container/startup/35-claude-auth-watcher.sh

# Install bashrc hook as fallback detection mechanism
install -m 755 /tmp/build-scripts/features/lib/claude/90-claude-auth-check.sh \
    /etc/bashrc.d/90-claude-auth-check.sh

# ============================================================================
# Install Claude Environment Configuration
# ============================================================================
log_message "Installing Claude environment configuration..."
mkdir -p /etc/bashrc.d
install -m 755 /tmp/build-scripts/features/lib/claude/95-claude-env.sh \
    /etc/bashrc.d/95-claude-env.sh

# Install inotify-tools for efficient file watching (if apt available)
if command -v apt-get &>/dev/null; then
    log_message "Installing inotify-tools for efficient authentication detection..."
    apt-get update -qq && apt-get install -y -qq inotify-tools 2>/dev/null || \
        log_warning "Could not install inotify-tools (watcher will use polling)"
fi

# ============================================================================
# Feature Summary
# ============================================================================
log_feature_summary \
    --feature "Claude Code Setup" \
    --tools "claude,claude-setup,claude-auth-watcher,bash-language-server" \
    --paths "/usr/local/bin/claude,/usr/local/bin/claude-setup,/usr/local/bin/claude-auth-watcher,/etc/container/first-startup/30-claude-code-setup.sh,/etc/container/startup/35-claude-auth-watcher.sh" \
    --env "ENABLE_LSP_TOOL,ANTHROPIC_AUTH_TOKEN,ANTHROPIC_MODEL,CLAUDE_CHANNEL,CLAUDE_EXTRA_PLUGINS,CLAUDE_EXTRA_MCPS,CLAUDE_USER_MCPS,CLAUDE_AUTO_DETECT_MCPS,CLAUDE_MCP_AUTO_AUTH,CLAUDE_AUTH_WATCHER_TIMEOUT" \
    --commands "claude,claude-setup,claude-auth-watcher" \
    --next-steps "Run 'claude' to authenticate. Setup runs automatically after auth (via watcher). Manual: 'claude-setup'."

# End logging
log_feature_end

echo ""
echo "Run 'claude' to authenticate, then 'claude-setup' to install plugins"
echo "Run 'check-build-logs.sh claude-code-setup' to review installation logs"
