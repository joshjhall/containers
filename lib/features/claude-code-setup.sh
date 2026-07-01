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
    latest | stable) ;;
    *)
        log_error "Invalid CLAUDE_CHANNEL: '$CLAUDE_CHANNEL' (must be 'latest' or 'stable')"
        exit 1
        ;;
esac
log_message "Using Claude Code channel: ${CLAUDE_CHANNEL}"

# Get the target user's home directory
TARGET_USER="${USERNAME:-developer}"
if [ "$TARGET_USER" = "root" ]; then
    USER_HOME="/root"
else
    USER_HOME="/home/$TARGET_USER"
fi

# Security Note: The Claude install script (https://claude.ai/install.sh) is a
# dynamic endpoint that changes with each release, so external checksum pinning
# is impractical. Security relies on:
# 1. TLS verification of the download from claude.ai
# 2. The installer's own internal verification:
#    a. Downloads manifest.json with expected SHA256 checksums
#    b. Downloads the binary
#    c. Verifies downloaded binary matches expected checksum using sha256sum
#    d. Fails installation if verification fails

# Download Claude Code installer via TLS (no external checksum available)
CLAUDE_INSTALLER_URL="https://claude.ai/install.sh"
BUILD_TEMP=$(create_secure_temp_dir)
log_message "Downloading Claude Code installer..."
if _curl_with_retry_wrapper -fsSL "$CLAUDE_INSTALLER_URL" -o "${BUILD_TEMP}/claude-install.sh"; then
    log_message "✓ Claude Code installer downloaded (verified via TLS + installer's internal binary checksum)"
else
    log_warning "Failed to download Claude Code installer"
    log_warning "Claude Code will not be available in this container"
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
# Clone the librarian plugin marketplace at a pinned ref
# ============================================================================
# The general-purpose skills/agents live in the joshjhall/librarian plugin
# marketplace (epic #607). We clone it at a PINNED tag/branch into a durable
# image path (/opt/librarian) and register+install it offline from a *local*
# (on-disk) marketplace at runtime (see claude-setup). A directory-sourced
# marketplace needs no network and no auth, so the headless container stays
# reproducible and offline.
#
# The clone lives at /opt (image-resident, never clobbered by a ~/.claude home
# volume mount); the actual `plugin install` happens in claude-setup so a fresh
# home volume self-heals on every boot — mirroring the old skill/agent re-sync.
#
# LIBRARIAN_REF is the version contract (registered in bin/check-versions.sh for
# auto-patch). It must be a tag or branch — `git clone --branch` does not accept
# a bare commit SHA. A bad ref FAILS THE BUILD: the pin is load-bearing, so we do
# not mask a clone failure here (unlike the best-effort CLI install above).
LIBRARIAN_REF="${LIBRARIAN_REF:-v0.3.0}"
LIBRARIAN_REPO_URL="${LIBRARIAN_REPO_URL:-https://github.com/joshjhall/librarian}"
LIBRARIAN_DIR="/opt/librarian"
log_message "Cloning librarian marketplace ${LIBRARIAN_REPO_URL} @ ${LIBRARIAN_REF}..."

# Remove any partial prior clone so a retry starts clean.
rm -rf "$LIBRARIAN_DIR"
if retry_command "Cloning librarian @ ${LIBRARIAN_REF}" \
    git clone --depth 1 --branch "$LIBRARIAN_REF" \
    "$LIBRARIAN_REPO_URL" "$LIBRARIAN_DIR"; then
    # Drop the .git dir — a local marketplace only needs the working tree, and
    # this trims image size.
    rm -rf "$LIBRARIAN_DIR/.git"
    # World-readable so the runtime user can register + install from it.
    chmod -R a+rX "$LIBRARIAN_DIR"
    log_message "✓ librarian cloned to ${LIBRARIAN_DIR} @ ${LIBRARIAN_REF}"
else
    log_error "Failed to clone librarian marketplace at ref '${LIBRARIAN_REF}'"
    log_error "LIBRARIAN_REF must be a valid tag or branch in ${LIBRARIAN_REPO_URL}"
    exit 1
fi

# ============================================================================
# Configure Claude Code Settings (memory, permissions)
# ============================================================================
# - Persist auto memory to the project directory so it survives container
#   rebuilds (the default ~/.claude/projects/<hash>/memory/ is ephemeral)
# - Pre-allow Read access to skills, agents, and memory paths so users aren't
#   constantly prompted for permission in the container
log_message "Configuring Claude Code settings..."

CLAUDE_SETTINGS_DIR="$USER_HOME/.claude"
CLAUDE_SETTINGS_FILE="$CLAUDE_SETTINGS_DIR/settings.json"
AUTO_MEMORY_DIR="${WORKING_DIR}/.claude/memory"

# Permission entries to auto-allow reading skills, agents, and memory files.
# Covers both user-level (~/.claude/) and project-level (.claude/) paths.
DEFAULT_PERMISSIONS='[
  "Read(~/.claude/skills/**)",
  "Read(~/.claude/agents/**)",
  "Read(~/.claude/memory/**)",
  "Read(.claude/skills/**)",
  "Read(.claude/agents/**)",
  "Read(.claude/memory/**)"
]'

# Default connect timeout (ms) for the Claude Code API client. The built-in
# default is 60s, which can trip on long requests once the context window grows
# well past ~200-300k tokens (the 1M-token ceiling allows for these). 600000 =
# 10 minutes — long enough for those calls while still failing a truly stuck
# connection. Override at runtime via the CLAUDE_CODE_CONNECT_TIMEOUT_MS env var.
DEFAULT_CONNECT_TIMEOUT_MS="600000"

# The orchestrate golem Notification hook (the "BLOCKED — needs a human" feed
# signal) is no longer wired here. It ships as part of the librarian *workflow*
# plugin, which carries its own hooks/hooks.json — Claude Code auto-wires the
# Notification event to `${CLAUDE_PLUGIN_ROOT}/hooks/golem-notify.sh` when that
# plugin is installed (offline, on every boot; see claude-setup). The old
# build-bound copy under templates/claude/hooks was removed in #611, so wiring a
# bare ~/.claude/hooks/golem-notify.sh path here would only dangle.

mkdir -p "$CLAUDE_SETTINGS_DIR"

if [ -f "$CLAUDE_SETTINGS_FILE" ]; then
    # Merge into existing settings.json (preserves existing permissions via
    # unique; keeps any pre-existing connect timeout rather than clobbering it)
    /usr/bin/jq --arg dir "$AUTO_MEMORY_DIR" --argjson perms "$DEFAULT_PERMISSIONS" \
        --arg timeout "$DEFAULT_CONNECT_TIMEOUT_MS" '
        .autoMemoryDirectory = $dir
        | .permissions.allow = ((.permissions.allow // []) + $perms | unique)
        | .env.CLAUDE_CODE_CONNECT_TIMEOUT_MS = (.env.CLAUDE_CODE_CONNECT_TIMEOUT_MS // $timeout)
    ' "$CLAUDE_SETTINGS_FILE" >"${CLAUDE_SETTINGS_FILE}.tmp" &&
        mv "${CLAUDE_SETTINGS_FILE}.tmp" "$CLAUDE_SETTINGS_FILE"
    log_message "Merged settings into existing settings.json"
else
    # Create new settings.json with autoMemoryDirectory, default permissions,
    # and the connect-timeout env default
    /usr/bin/jq -n --arg dir "$AUTO_MEMORY_DIR" --argjson perms "$DEFAULT_PERMISSIONS" \
        --arg timeout "$DEFAULT_CONNECT_TIMEOUT_MS" \
        '{autoMemoryDirectory: $dir, permissions: {allow: $perms}, env: {CLAUDE_CODE_CONNECT_TIMEOUT_MS: $timeout}}' \
        >"$CLAUDE_SETTINGS_FILE"
    log_message "Created settings.json with autoMemoryDirectory, default permissions, and connect timeout"
fi

chown -R "$TARGET_USER:$TARGET_USER" "$CLAUDE_SETTINGS_DIR"
log_message "Auto memory directory set to $AUTO_MEMORY_DIR"
log_message "Default read permissions configured for skills, agents, and memory paths"

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
        source /tmp/build-scripts/features/lib/claude/mcp-registry.sh

        IFS=',' read -ra EXTRA_MCP_LIST <<<"$EXTRA_MCPS_TO_INSTALL"
        for mcp_name in "${EXTRA_MCP_LIST[@]}"; do
            mcp_name=$(echo "$mcp_name" | xargs) # Trim whitespace
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
        cp /tmp/build-scripts/features/lib/claude/mcp-registry.sh /etc/container/config/mcp-registry.sh
    log_command "Setting MCP registry permissions" \
        chmod 644 /etc/container/config/mcp-registry.sh

    log_message "MCP servers installed successfully"
else
    log_message "Node.js not available - skipping MCP servers and bash-language-server"
    log_message "To enable MCP servers, add INCLUDE_NODE=true or INCLUDE_NODE_DEV=true"
fi

# ============================================================================
# Stage Build-Bound Skill Templates for Runtime Installation
# ============================================================================
# The general-purpose skills/agents/hooks now ship via the librarian plugin
# marketplace (cloned above; installed at runtime by claude-setup) — they were
# removed from lib/features/templates/claude in #611. What still stages here are
# the BUILD-BOUND skills that intentionally stay in this repo: the
# docker-development skill template (container-environment and cloud-infrastructure
# are generated dynamically at runtime, not from templates).
#
# The #574 content-stamp re-sync machinery is removed — librarian plugins carry
# their own version contract (LIBRARIAN_REF), so the bespoke stamp is obsolete.
#
# NOTE: the staged tree is read by claude-setup (build-bound skills, CLAUDE_EXTRA_*
# additive installs).
log_message "Staging build-bound skill templates for runtime installation..."

if [ -d /tmp/build-scripts/features/templates/claude ]; then
    mkdir -p /etc/container/config/claude-templates
    cp -r /tmp/build-scripts/features/templates/claude/* /etc/container/config/claude-templates/
    chmod -R 644 /etc/container/config/claude-templates/
    command find /etc/container/config/claude-templates -type d -exec chmod 755 {} \;
    log_message "Build-bound skill templates staged"
else
    log_warning "No skill templates found at /tmp/build-scripts/features/templates/claude"
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

# ============================================================================
# Install ACP Agent Launch Wrapper
# ============================================================================
# Provider-neutral wrapper that re-injects the container's Anthropic creds into
# an editor-launched Claude Code ACP agent (e.g. Zed's AI panel), which bypasses
# the interactive `claude` bash wrapper and so never sees the stripped token.
# Reuses the /dev/shm token file written by 95-claude-env.sh. The Zed first-
# startup hook (dev-tools feature) points an agent_servers entry at this script.
log_message "Installing ACP agent launch wrapper..."
install -m 755 /tmp/build-scripts/features/lib/claude/claude-acp-launch \
    /usr/local/bin/claude-acp-launch

# Install inotify-tools for efficient file watching (if apt available)
if command -v apt-get &>/dev/null; then
    log_message "Installing inotify-tools for efficient authentication detection..."
    apt-get update -qq && apt-get install -y -qq inotify-tools 2>/dev/null ||
        log_warning "Could not install inotify-tools (watcher will use polling)"
fi

# ============================================================================
# Feature Summary
# ============================================================================
log_feature_summary \
    --feature "Claude Code Setup" \
    --tools "claude,claude-setup,claude-auth-watcher,bash-language-server" \
    --paths "/usr/local/bin/claude,/usr/local/bin/claude-setup,/usr/local/bin/claude-auth-watcher,/opt/librarian,/etc/container/first-startup/30-claude-code-setup.sh,/etc/container/startup/35-claude-auth-watcher.sh,~/.claude/settings.json" \
    --env "ENABLE_LSP_TOOL,ANTHROPIC_AUTH_TOKEN,ANTHROPIC_MODEL,CLAUDE_CHANNEL,CLAUDE_EXTRA_PLUGINS,CLAUDE_EXTRA_MCPS,CLAUDE_EXTRA_SKILLS,CLAUDE_EXTRA_AGENTS,CLAUDE_AUTO_DETECT_MCPS,CLAUDE_MCP_AUTO_AUTH,CLAUDE_AUTH_WATCHER_TIMEOUT,CLAUDE_PLUGINS,CLAUDE_MCPS,CLAUDE_AGENTS,CLAUDE_SKILLS,LIBRARIAN_REF,CLAUDE_LIBRARIAN_PLUGINS" \
    --commands "claude,claude-setup,claude-auth-watcher" \
    --next-steps "Run 'claude' to authenticate. Setup runs automatically after auth (via watcher). Manual: 'claude-setup'."

# End logging
log_feature_end

log_feature_instructions "claude" "claude-code-setup"
