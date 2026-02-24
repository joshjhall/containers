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
# Authentication Check (Token-based or OAuth)
# ============================================================================
is_claude_authenticated() {
    # Check for token-based authentication (via proxy like LiteLLM)
    if [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
        return 0
    fi

    # Try to resolve from 1Password (handles non-interactive contexts where
    # bashrc hasn't run, e.g. called from auth watcher or cron)
    if [ -n "${OP_ANTHROPIC_AUTH_TOKEN_REF:-}" ] && [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
        if command -v op &>/dev/null; then
            local resolved
            resolved=$(op read "${OP_ANTHROPIC_AUTH_TOKEN_REF}" 2>/dev/null) || true
            if [ -n "$resolved" ]; then
                export ANTHROPIC_AUTH_TOKEN="$resolved"
                # Also resolve base URL if ref exists
                if [ -n "${OP_ANTHROPIC_BASE_URL_REF:-}" ] && [ -z "${ANTHROPIC_BASE_URL:-}" ]; then
                    local base_url
                    base_url=$(op read "${OP_ANTHROPIC_BASE_URL_REF}" 2>/dev/null) || true
                    [ -n "$base_url" ] && export ANTHROPIC_BASE_URL="$base_url"
                fi
                return 0
            fi
        fi
    fi

    # Check for OAuth credentials (created by running 'claude' and authenticating)
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
# --force mode: skip plugins if unauthenticated (MCP/skills setup only)
# normal mode: install plugins if authenticated, show instructions otherwise
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
MARKETPLACE_REPO="anthropics/claude-plugins-official"
PLUGINS_INSTALLED=false

# Ensure the official marketplace is registered before attempting installs.
# With token-based auth (ANTHROPIC_AUTH_TOKEN), no interactive 'claude' session
# runs to trigger auto-registration, so we must do it explicitly.
ensure_marketplace() {
    # Check if marketplace is already registered (appears in known_marketplaces.json)
    local known_file="$HOME/.claude/plugins/known_marketplaces.json"
    if [ -f "$known_file" ] && grep -q "\"$MARKETPLACE\"" "$known_file" 2>/dev/null; then
        return 0
    fi

    echo "  Registering marketplace: $MARKETPLACE_REPO..."
    local output
    if output=$(claude plugin marketplace add "$MARKETPLACE_REPO" 2>&1); then
        echo "  ✓ Marketplace registered"
        return 0
    else
        echo "  ⚠ Failed to register marketplace: $output"
        return 1
    fi
}

# Pattern matching function (testable - takes list output as parameter)
# Output format from 'claude plugin list':
#   ❯ plugin-name@marketplace - description
#   ❯ another-plugin@marketplace - description
_match_plugin_in_list() {
    local plugin_name="$1"
    local list_output="$2"
    # Match: "❯ plugin-name@" at start of line (after any whitespace)
    # The ❯ character is followed by space, then plugin name, then @
    echo "$list_output" | grep -qE "^[[:space:]]*❯ ${plugin_name}@" 2>/dev/null
}

has_plugin() {
    local plugin_name="$1"
    local list_output
    list_output=$(claude plugin list 2>/dev/null) || return 1
    _match_plugin_in_list "$plugin_name" "$list_output"
}

install_plugin() {
    local plugin_name="$1"
    local full_name="${plugin_name}@${MARKETPLACE}"

    if has_plugin "$plugin_name"; then
        echo "    ✓ $plugin_name (already installed)"
        return 0
    fi

    echo "  - Installing $plugin_name..."

    # Retry with exponential backoff for "not found" errors
    # This handles the race condition where auth is detected but
    # the marketplace API isn't fully ready yet
    local max_retries=4
    local retry_delay=2
    local attempt=1
    local output

    while [ $attempt -le $max_retries ]; do
        if output=$(claude plugin install "$full_name" 2>&1); then
            echo "    ✓ $plugin_name installed"
            PLUGINS_INSTALLED=true
            return 0
        fi

        # Check if this is a "not found" error (marketplace not ready)
        if echo "$output" | grep -q "not found in marketplace"; then
            if [ $attempt -lt $max_retries ]; then
                echo "    ⏳ Marketplace not ready, retrying in ${retry_delay}s... (attempt $attempt/$max_retries)"
                sleep $retry_delay
                retry_delay=$((retry_delay * 2))  # Exponential backoff: 2, 4, 8, 16
                attempt=$((attempt + 1))
                continue
            fi
        fi

        # Non-retryable error or max retries reached
        echo "    ⚠ Failed to install $plugin_name"
        echo "$output" | sed 's/^/      /' | head -5
        return 1
    done

    return 1
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
    if [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
        echo "Authentication: Token (ANTHROPIC_AUTH_TOKEN)"
    elif [ -f ~/.claude/.credentials.json ] && grep -q '"claudeAiOauth"' ~/.claude/.credentials.json 2>/dev/null; then
        echo "Authentication: OAuth (interactive)"
    elif [ -f ~/.claude.json ] && grep -q '"oauthAccount"' ~/.claude.json 2>/dev/null; then
        echo "Authentication: OAuth account"
    else
        echo "Authentication: Detected"
    fi
    echo ""
    echo "Installing plugins..."
    echo ""

    # Ensure marketplace is registered before attempting installs
    if ! ensure_marketplace; then
        echo "  ⚠ Could not register marketplace. Plugin installation may fail."
        echo ""
    fi

    # Core Plugins (Always Installed)
    echo "Core plugins:"
    install_plugin "commit-commands" || true
    install_plugin "frontend-design" || true
    install_plugin "code-simplifier" || true
    install_plugin "context7" || true
    install_plugin "security-guidance" || true
    install_plugin "claude-md-management" || true
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

# Pattern matching function (testable - takes list output as parameter)
# Output format from 'claude mcp list':
#   servername: npx -y @modelcontextprotocol/server-xxx - running
#   another-server: command args - stopped
_match_mcp_server_in_list() {
    local server_name="$1"
    local list_output="$2"
    # Match: server name at start of line followed by colon
    echo "$list_output" | grep -qE "^${server_name}:" 2>/dev/null
}

has_mcp_server() {
    local server_name="$1"
    local list_output
    list_output=$(claude mcp list 2>/dev/null) || return 1
    _match_mcp_server_in_list "$server_name" "$list_output"
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
    local output
    if output=$(claude mcp add -s user "${args[@]}" 2>&1); then
        echo "    ✓ $server_name added"
        return 0
    else
        # Check if it's actually an "already exists" message (not a real failure)
        if echo "$output" | grep -q "already exists"; then
            echo "    ✓ $server_name (already configured)"
            return 0
        fi
        echo "    ⚠ Failed to add $server_name"
        echo "$output" | sed 's/^/      /' | head -3
        return 1
    fi
}

# ============================================================================
# MCP Helper: Inject headers into HTTP MCP server config via jq
# ============================================================================
inject_mcp_headers() {
    local server_name="$1"
    local headers_str="$2"
    local config_file="$HOME/.claude.json"

    [ -z "$headers_str" ] && return 0

    # Ensure config file exists with valid JSON
    if [ ! -f "$config_file" ]; then
        echo '{}' > "$config_file"
    fi

    # Parse pipe-delimited headers and inject via jq
    IFS='|' read -ra HEADER_PAIRS <<< "$headers_str"
    for header_pair in "${HEADER_PAIRS[@]}"; do
        header_pair=$(echo "$header_pair" | xargs)  # Trim whitespace
        [ -z "$header_pair" ] && continue

        # Split on first colon only (value may contain colons)
        local header_key="${header_pair%%:*}"
        local header_value="${header_pair#*:}"
        header_key=$(echo "$header_key" | xargs)
        header_value=$(echo "$header_value" | xargs)

        [ -z "$header_key" ] && continue

        local tmp_file
        tmp_file=$(mktemp)
        if jq --arg name "$server_name" --arg key "$header_key" --arg val "$header_value" \
            '.mcpServers[$name].headers[$key] = $val' \
            "$config_file" > "$tmp_file" 2>/dev/null; then
            mv "$tmp_file" "$config_file"
        else
            rm -f "$tmp_file"
            echo "    ⚠ Failed to inject header $header_key for $server_name"
        fi
    done
}

# ============================================================================
# MCP Helper: Auto-inject Authorization header for HTTP MCP servers
# ============================================================================
inject_mcp_auth_header() {
    local server_name="$1"
    local config_file="$HOME/.claude.json"

    # Ensure config file exists with valid JSON
    if [ ! -f "$config_file" ]; then
        echo '{}' > "$config_file"
    fi

    # Skip if Authorization header already exists
    if jq -e --arg name "$server_name" \
        '.mcpServers[$name].headers.Authorization // empty' \
        "$config_file" >/dev/null 2>&1; then
        return 0
    fi

    # Write the ${ANTHROPIC_AUTH_TOKEN} env var reference (not the literal value)
    local tmp_file
    tmp_file=$(mktemp)
    if jq --arg name "$server_name" \
        '.mcpServers[$name].headers.Authorization = "Bearer ${ANTHROPIC_AUTH_TOKEN}"' \
        "$config_file" > "$tmp_file" 2>/dev/null; then
        mv "$tmp_file" "$config_file"
        echo "    ✓ Auto-injected Authorization header for $server_name"
    else
        rm -f "$tmp_file"
        echo "    ⚠ Failed to auto-inject Authorization header for $server_name"
    fi
}

# ============================================================================
# MCP Helper: Derive short name from npm package
# ============================================================================
derive_mcp_name_from_package() {
    local pkg="$1"
    # Extract last segment after / (e.g., @foo/bar-server -> bar-server)
    echo "${pkg##*/}"
}

# ============================================================================
# MCP Helper: Configure a comma-separated list of MCPs (registry + passthrough)
# ============================================================================
configure_mcp_list() {
    local mcp_list="$1"
    local label="$2"

    [ -z "$mcp_list" ] && return 0

    echo "Configuring ${label}..."

    local registry="$MCP_REGISTRY"
    local has_registry=false
    if [ -f "$registry" ]; then
        # shellcheck source=/dev/null
        source "$registry"
        has_registry=true
    fi

    local required_env_vars=""
    IFS=',' read -ra MCP_ITEMS <<< "$mcp_list"
    for mcp_entry in "${MCP_ITEMS[@]}"; do
        mcp_entry=$(echo "$mcp_entry" | xargs)  # Trim whitespace
        [ -z "$mcp_entry" ] && continue

        # Check for name=url syntax (HTTP MCP servers), with optional pipe-delimited headers
        # Format: name=url or name=url|Header1:Value1|Header2:Value2
        if [[ "$mcp_entry" == *=http://* ]] || [[ "$mcp_entry" == *=https://* ]]; then
            local http_name="${mcp_entry%%=*}"
            # Validate server name: must be non-empty, alphanumeric with hyphens/underscores
            if [[ ! "$http_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
                echo "  ⚠ Skipping HTTP MCP with invalid name: '$http_name'"
                continue
            fi
            local http_rest="${mcp_entry#*=}"
            # Split on pipe: first segment is URL, remaining are headers
            local http_url="${http_rest%%|*}"
            # Normalize URL: ensure trailing slash to avoid redirect chains
            # that strip Authorization headers (HTTPS->HTTP redirect security)
            [[ "$http_url" != */ ]] && http_url="${http_url}/"
            # Validate URL scheme: only http:// (localhost only) and https://
            if [[ "$http_url" =~ ^https:// ]]; then
                : # HTTPS always allowed
            elif [[ "$http_url" =~ ^http://(localhost|127\.0\.0\.1|\[::1\]|host\.docker\.internal)(:|/) ]]; then
                : # HTTP allowed for localhost only
            else
                echo "  ⚠ Skipping HTTP MCP '$http_name': URL must be https:// or http://localhost"
                continue
            fi
            local http_headers_str=""
            if [[ "$http_rest" == *"|"* ]]; then
                http_headers_str="${http_rest#*|}"
            fi
            echo "  - HTTP MCP: $http_name -> $http_url"
            add_mcp_server "$http_name" -t http "$http_name" "$http_url" || true

            # Inject explicit pipe-delimited headers
            local has_explicit_auth=false
            if [ -n "$http_headers_str" ]; then
                # Check if Authorization was explicitly provided before injecting
                if echo "$http_headers_str" | grep -qiE '(^|[|])Authorization:'; then
                    has_explicit_auth=true
                fi
                inject_mcp_headers "$http_name" "$http_headers_str"
            fi

            # Auto-inject auth header when:
            # - No explicit Authorization header was provided
            # - CLAUDE_MCP_AUTO_AUTH is not disabled (default: true)
            # - ANTHROPIC_AUTH_TOKEN is set in the environment
            if [ "$has_explicit_auth" = "false" ] && \
               [ "${CLAUDE_MCP_AUTO_AUTH:-true}" != "false" ] && \
               [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
                inject_mcp_auth_header "$http_name"
            fi
            continue
        fi

        local mcp_name="$mcp_entry"
        if [ "$has_registry" = "true" ] && mcp_registry_is_registered "$mcp_name"; then
            # Known name: use registry
            # Split registry args into array (safe: add_args comes from hardcoded registry strings)
            add_args=$(mcp_registry_get_add_args "$mcp_name")
            eval "local add_args_array=($add_args)"
            add_mcp_server "$mcp_name" "${add_args_array[@]}" || true

            env_docs=$(mcp_registry_get_env_docs "$mcp_name")
            if [ -n "$env_docs" ]; then
                required_env_vars="${required_env_vars:+$required_env_vars, }${mcp_name}: ${env_docs}"
            fi
        else
            # Unknown name: passthrough as npx -y <package>
            # Validate npm package name to prevent command injection
            if [[ ! "$mcp_name" =~ ^[@a-zA-Z0-9][-a-zA-Z0-9_./@]*$ ]]; then
                echo "  ⚠ Skipping MCP with invalid package name: '$mcp_name'"
                continue
            fi
            local short_name
            short_name=$(derive_mcp_name_from_package "$mcp_name")
            echo "  - Passthrough: $mcp_name (as $short_name via npx)"
            add_mcp_server "$short_name" -t stdio "$short_name" -- npx -y "$mcp_name" || true
        fi
    done

    if [ -n "$required_env_vars" ]; then
        echo ""
        echo "  Required environment variables for ${label}:"
        echo "    $required_env_vars"
    fi
    echo ""
}

# Filesystem MCP (always)
add_mcp_server "filesystem" -t stdio "filesystem" -- npx -y @modelcontextprotocol/server-filesystem /workspace || true

# Figma desktop MCP (always - connects to Figma desktop app via Docker host)
add_mcp_server "figma-desktop" -t http "figma-desktop" "http://host.docker.internal:3845/mcp" || true

# ============================================================================
# Extra MCP Servers (from CLAUDE_EXTRA_MCPS)
# ============================================================================
# GitHub and GitLab MCPs are now optional - add them via CLAUDE_EXTRA_MCPS.
# Example: CLAUDE_EXTRA_MCPS="github,kagi,memory"
# Unknown names are passed through as npx -y <package>.
MCP_REGISTRY="/etc/container/config/mcp-registry.sh"
EXTRA_MCPS_TO_CONFIGURE="${CLAUDE_EXTRA_MCPS:-${CLAUDE_EXTRA_MCPS_DEFAULT:-}}"
configure_mcp_list "$EXTRA_MCPS_TO_CONFIGURE" "Extra MCP servers (CLAUDE_EXTRA_MCPS)"

# ============================================================================
# User MCP Servers (from CLAUDE_USER_MCPS - runtime-only, personal additions)
# ============================================================================
# Personal MCP additions via .env without modifying shared config.
# Known names resolved via registry; unknown names passed to npx -y <package>.
# Example: CLAUDE_USER_MCPS="my-custom-server,@myorg/mcp-internal"
USER_MCPS="${CLAUDE_USER_MCPS:-}"
configure_mcp_list "$USER_MCPS" "User MCP servers (CLAUDE_USER_MCPS)"

# ============================================================================
# Auto-detect GitHub/GitLab MCP from git remotes
# ============================================================================
# Inspects git repos under /workspace to auto-add platform MCPs when the
# corresponding token env var is set. Opt-out: CLAUDE_AUTO_DETECT_MCPS=false
if [ "${CLAUDE_AUTO_DETECT_MCPS:-true}" != "false" ] && [ -f "$MCP_REGISTRY" ]; then
    # Ensure registry is sourced
    if ! type mcp_registry_is_registered &>/dev/null; then
        # shellcheck source=/dev/null
        source "$MCP_REGISTRY"
    fi

    DETECTED_GITHUB=false
    DETECTED_GITLAB=false

    # Find git repos under /workspace (limit depth to avoid deep traversal)
    while IFS= read -r git_dir; do
        repo_dir=$(dirname "$git_dir")
        remote_urls=$(git -C "$repo_dir" remote -v 2>/dev/null || true)

        if [ -n "$remote_urls" ]; then
            if echo "$remote_urls" | grep -qi 'github\.com' 2>/dev/null; then
                DETECTED_GITHUB=true
            fi
            if echo "$remote_urls" | grep -qiE 'gitlab\.com|gitlab\.' 2>/dev/null; then
                DETECTED_GITLAB=true
            fi
        fi
    done < <(find /workspace -maxdepth 4 -name .git -type d 2>/dev/null)

    if [ "$DETECTED_GITHUB" = "true" ]; then
        if [ -n "${GITHUB_TOKEN:-}" ]; then
            echo "Auto-detected GitHub remote with GITHUB_TOKEN set"
            add_args=$(mcp_registry_get_add_args "github")
            eval "local add_args_array=($add_args)"
            add_mcp_server "github" "${add_args_array[@]}" || true
        else
            echo "  Auto-detected GitHub remote but GITHUB_TOKEN not set (skipping github MCP)"
        fi
    fi

    if [ "$DETECTED_GITLAB" = "true" ]; then
        if [ -n "${GITLAB_TOKEN:-}" ]; then
            echo "Auto-detected GitLab remote with GITLAB_TOKEN set"
            add_args=$(mcp_registry_get_add_args "gitlab")
            eval "local add_args_array=($add_args)"
            add_mcp_server "gitlab" "${add_args_array[@]}" || true
        else
            echo "  Auto-detected GitLab remote but GITLAB_TOKEN not set (skipping gitlab MCP)"
        fi
    fi

    echo ""
fi

# ============================================================================
# Skills & Agents Installation
# ============================================================================
TEMPLATES_DIR="/etc/container/config/claude-templates"
CLAUDE_DIR="$HOME/.claude"

if [ -d "$TEMPLATES_DIR" ]; then
    echo "Installing skills and agents..."
    echo ""

    # --- Static Skills ---
    echo "Skills:"
    if [ -d "$TEMPLATES_DIR/skills" ]; then
        for skill_dir in "$TEMPLATES_DIR/skills"/*/; do
            [ -d "$skill_dir" ] || continue
            skill_name=$(basename "$skill_dir")

            # Skip conditional skills (handled below)
            [ "$skill_name" = "container-environment" ] && continue
            [ "$skill_name" = "docker-development" ] && continue
            [ "$skill_name" = "cloud-infrastructure" ] && continue

            target_dir="$CLAUDE_DIR/skills/$skill_name"
            if [ -d "$target_dir" ]; then
                echo "    ✓ $skill_name (already installed)"
            else
                mkdir -p "$target_dir"
                cp "$skill_dir"/* "$target_dir/"
                echo "    ✓ $skill_name installed"
            fi
        done
    fi

    # --- Dynamic: container-environment skill ---
    target_dir="$CLAUDE_DIR/skills/container-environment"
    if [ -d "$target_dir" ]; then
        echo "    ✓ container-environment (already installed)"
    else
        mkdir -p "$target_dir"
        # Generate dynamic content from enabled-features.conf
        {
            cat << 'SKILL_HEADER'
---
description: "Container development environment details and available tools"
---
# Container Environment

This skill describes the development container environment, installed tools,
and container-specific patterns.

## Container Patterns
- Working directory: /workspace
- Non-root user (configurable via USERNAME build arg)
- tini as PID 1 for zombie process reaping
- First-startup scripts in /etc/container/first-startup/
- Startup scripts in /etc/container/startup/
- Build logs available via: check-build-logs.sh <feature-name>

## Cache Paths
All caches are under /cache/ for Docker volume persistence:
- pip: /cache/pip
- npm: /cache/npm
- cargo: /cache/cargo
- go: /cache/go
- bundle: /cache/bundle
- dev-tools: /cache/dev-tools

SKILL_HEADER
            echo "## Installed Languages & Tools"
            if [ -f "$ENABLED_FEATURES_FILE" ]; then
                [ "${INCLUDE_PYTHON_DEV:-false}" = "true" ] && echo "- Python (dev tools: yes)"
                [ "${INCLUDE_NODE_DEV:-false}" = "true" ] && echo "- Node.js (dev tools: yes)"
                [ "${INCLUDE_RUST_DEV:-false}" = "true" ] && echo "- Rust (dev tools: yes)"
                [ "${INCLUDE_RUBY_DEV:-false}" = "true" ] && echo "- Ruby (dev tools: yes)"
                [ "${INCLUDE_GOLANG_DEV:-false}" = "true" ] && echo "- Go (dev tools: yes)"
                [ "${INCLUDE_JAVA_DEV:-false}" = "true" ] && echo "- Java (dev tools: yes)"
                [ "${INCLUDE_KOTLIN_DEV:-false}" = "true" ] && echo "- Kotlin (dev tools: yes)"
                [ "${INCLUDE_ANDROID_DEV:-false}" = "true" ] && echo "- Android (dev tools: yes)"
                [ "${INCLUDE_DOCKER:-false}" = "true" ] && echo "- Docker CLI"
                [ "${INCLUDE_KUBERNETES:-false}" = "true" ] && echo "- Kubernetes (kubectl, helm, k9s)"
                [ "${INCLUDE_TERRAFORM:-false}" = "true" ] && echo "- Terraform"
                [ "${INCLUDE_AWS:-false}" = "true" ] && echo "- AWS CLI"
                [ "${INCLUDE_GCLOUD:-false}" = "true" ] && echo "- Google Cloud SDK"
                [ "${INCLUDE_CLOUDFLARE:-false}" = "true" ] && echo "- Cloudflare tools"
            fi
            echo ""
            echo "## Useful Commands"
            echo "- check-build-logs.sh <feature> - View build logs for a feature"
            echo "- check-installed-versions.sh - Show installed tool versions"
            echo "- test-dev-tools - Verify development tool installation"
        } > "$target_dir/SKILL.md"
        echo "    ✓ container-environment installed (dynamic)"
    fi

    # --- Conditional: docker-development skill ---
    if [ "${INCLUDE_DOCKER:-false}" = "true" ]; then
        target_dir="$CLAUDE_DIR/skills/docker-development"
        if [ -d "$target_dir" ]; then
            echo "    ✓ docker-development (already installed)"
        else
            mkdir -p "$target_dir"
            cp "$TEMPLATES_DIR/skills/docker-development/"* "$target_dir/"
            echo "    ✓ docker-development installed"
        fi
    fi

    # --- Dynamic: cloud-infrastructure skill ---
    HAS_CLOUD=false
    [ "${INCLUDE_KUBERNETES:-false}" = "true" ] && HAS_CLOUD=true
    [ "${INCLUDE_TERRAFORM:-false}" = "true" ] && HAS_CLOUD=true
    [ "${INCLUDE_AWS:-false}" = "true" ] && HAS_CLOUD=true
    [ "${INCLUDE_GCLOUD:-false}" = "true" ] && HAS_CLOUD=true
    [ "${INCLUDE_CLOUDFLARE:-false}" = "true" ] && HAS_CLOUD=true

    if [ "$HAS_CLOUD" = "true" ]; then
        target_dir="$CLAUDE_DIR/skills/cloud-infrastructure"
        if [ -d "$target_dir" ]; then
            echo "    ✓ cloud-infrastructure (already installed)"
        else
            mkdir -p "$target_dir"
            {
                cat << 'CLOUD_HEADER'
---
description: "Cloud infrastructure tools available in this container"
---
# Cloud Infrastructure

## Available Tools
CLOUD_HEADER
                [ "${INCLUDE_KUBERNETES:-false}" = "true" ] && echo "- Kubernetes: kubectl, helm, k9s, krew"
                [ "${INCLUDE_TERRAFORM:-false}" = "true" ] && echo "- Terraform: terraform, terragrunt, tflint, terraform-docs"
                [ "${INCLUDE_AWS:-false}" = "true" ] && echo "- AWS: aws CLI"
                [ "${INCLUDE_GCLOUD:-false}" = "true" ] && echo "- Google Cloud: gcloud, gsutil, bq"
                [ "${INCLUDE_CLOUDFLARE:-false}" = "true" ] && echo "- Cloudflare: wrangler"
                echo ""
                echo "## General Patterns"
                echo "- Use infrastructure-as-code (Terraform, CloudFormation, etc.)"
                echo "- Keep credentials in environment variables, never in code"
                echo "- Use least-privilege IAM roles and service accounts"
                echo "- Tag resources for cost tracking and ownership"
                echo "- Use separate environments (dev, staging, production)"
            } > "$target_dir/SKILL.md"
            echo "    ✓ cloud-infrastructure installed (dynamic)"
        fi
    fi

    # --- Agents ---
    echo ""
    echo "Agents:"
    if [ -d "$TEMPLATES_DIR/agents" ]; then
        for agent_dir in "$TEMPLATES_DIR/agents"/*/; do
            [ -d "$agent_dir" ] || continue
            agent_name=$(basename "$agent_dir")

            target_dir="$CLAUDE_DIR/agents/$agent_name"
            if [ -d "$target_dir" ]; then
                echo "    ✓ $agent_name (already installed)"
            else
                mkdir -p "$target_dir"
                cp "$agent_dir"/* "$target_dir/"
                echo "    ✓ $agent_name installed"
            fi
        done
    fi

    echo ""
fi

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Verify with:"
echo "  claude plugin list  - See installed plugins"
echo "  claude mcp list     - See configured MCP servers"
echo "  ls ~/.claude/skills/ - See installed skills"
echo "  ls ~/.claude/agents/ - See installed agents"
echo ""
if ! is_claude_authenticated; then
    echo "Note: Plugins were not installed (not authenticated)."
    echo "After running 'claude' and authenticating, run 'claude-setup' again."
    echo ""
fi
echo "Environment: ENABLE_LSP_TOOL=1"
echo "Add github or gitlab to CLAUDE_EXTRA_MCPS for git platform MCP access."
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
# Auto-Setup Watcher (Detects authentication and runs claude-setup)
# ============================================================================
log_message "Creating authentication watcher scripts..."

# Create the watcher script that monitors for credential file changes
command cat > /usr/local/bin/claude-auth-watcher << 'AUTH_WATCHER_EOF'
#!/bin/bash
# claude-auth-watcher - Watches for Claude authentication and runs setup
#
# This script runs in the background after container startup. It watches for
# Claude credential files to appear (created when user runs 'claude') and
# automatically triggers claude-setup when authentication is detected.
#
# Uses inotifywait for efficient event-driven detection, with polling fallback.
#
# Environment Variables:
#   CLAUDE_AUTH_WATCHER_TIMEOUT: Timeout in seconds (default: 14400 = 4 hours)
#   CLAUDE_AUTH_WATCHER_INTERVAL: Polling interval in seconds (default: 30)

set -euo pipefail

# Configuration
TIMEOUT="${CLAUDE_AUTH_WATCHER_TIMEOUT:-14400}"  # 4 hours default
POLL_INTERVAL="${CLAUDE_AUTH_WATCHER_INTERVAL:-30}"
CLAUDE_DIR="$HOME/.claude"
MARKER_FILE="$CLAUDE_DIR/.container-setup-complete"
CREDENTIALS_FILE="$CLAUDE_DIR/.credentials.json"

log() {
    echo "[claude-auth-watcher] $(date '+%Y-%m-%d %H:%M:%S') $*"
}

# Check if setup has already been completed
if [ -f "$MARKER_FILE" ]; then
    log "Setup already completed (marker file exists). Exiting."
    exit 0
fi

# Try to resolve secrets from 1Password (for background processes that
# started before OP resolution ran in bashrc/startup scripts)
_try_resolve_op_secrets() {
    # Already resolved or no OP ref available
    [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ] && return 0

    # Need both the ref and service account token
    [ -z "${OP_ANTHROPIC_AUTH_TOKEN_REF:-}" ] && return 1
    [ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ] && return 1
    command -v op &>/dev/null || return 1

    local resolved
    resolved=$(op read "${OP_ANTHROPIC_AUTH_TOKEN_REF}" 2>/dev/null) || return 1
    if [ -n "$resolved" ]; then
        export ANTHROPIC_AUTH_TOKEN="$resolved"
        log "Resolved ANTHROPIC_AUTH_TOKEN from 1Password"

        # Also resolve ANTHROPIC_BASE_URL if ref exists
        if [ -n "${OP_ANTHROPIC_BASE_URL_REF:-}" ] && [ -z "${ANTHROPIC_BASE_URL:-}" ]; then
            local base_url
            base_url=$(op read "${OP_ANTHROPIC_BASE_URL_REF}" 2>/dev/null) || true
            if [ -n "$base_url" ]; then
                export ANTHROPIC_BASE_URL="$base_url"
                log "Resolved ANTHROPIC_BASE_URL from 1Password"
            fi
        fi
        return 0
    fi
    return 1
}

# Check if already authenticated
is_authenticated() {
    # Check for token-based authentication (via proxy like LiteLLM)
    if [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
        return 0
    fi

    # Try to resolve from 1Password (handles case where watcher started
    # before OP secrets were resolved by startup scripts)
    if _try_resolve_op_secrets; then
        return 0
    fi

    # Check for OAuth credentials
    if [ -f "$CREDENTIALS_FILE" ]; then
        if grep -q '"claudeAiOauth"' "$CREDENTIALS_FILE" 2>/dev/null; then
            return 0
        fi
    fi
    if [ -f "$HOME/.claude.json" ]; then
        if grep -q '"oauthAccount"' "$HOME/.claude.json" 2>/dev/null; then
            # Verify it's not null/empty (same check as claude-setup)
            if jq -e '.oauthAccount != null and .oauthAccount != ""' "$HOME/.claude.json" >/dev/null 2>&1; then
                return 0
            fi
        fi
    fi
    return 1
}

# Quick test if the Claude plugin marketplace is reachable.
# Exit code 0 from 'claude plugin list' confirms connectivity;
# empty output is valid (first run, no plugins installed yet)
_is_marketplace_available() {
    local output
    output=$(timeout 10 claude plugin list 2>&1) || return 1
    # Error indicators mean marketplace is down/unauthorized
    echo "$output" | grep -qi "error\|unauthorized\|forbidden\|unavailable" && return 1
    return 0
}

# Ensure the official marketplace is registered (for the watcher context).
# claude-setup has its own ensure_marketplace, but we also pre-register here
# so the availability check is meaningful.
_ensure_marketplace_registered() {
    local known_file="$HOME/.claude/plugins/known_marketplaces.json"
    if [ -f "$known_file" ] && grep -q '"claude-plugins-official"' "$known_file" 2>/dev/null; then
        return 0
    fi
    log "Registering claude-plugins-official marketplace..."
    if claude plugin marketplace add "anthropics/claude-plugins-official" &>/dev/null; then
        log "Marketplace registered successfully"
        return 0
    else
        log "Failed to register marketplace (claude-setup will retry)"
        return 1
    fi
}

# Run setup and create marker file
run_setup() {
    log "Authentication detected! Checking marketplace availability..."

    # Ensure marketplace is registered before checking availability
    _ensure_marketplace_registered || true

    # Test marketplace before running setup
    # The install_plugin function has retry logic, but testing first avoids log noise
    if _is_marketplace_available; then
        log "Marketplace is available! Running claude-setup..."
    else
        log "Marketplace not yet available. Waiting 10s before retry..."
        sleep 10

        if ! _is_marketplace_available; then
            log "Marketplace still not available. Running setup anyway (has retry logic)..."
        fi
    fi

    if command -v claude-setup &>/dev/null; then
        if claude-setup 2>&1 | tee -a "/tmp/claude-auth-watcher.log"; then
            log "Setup completed successfully"
            mkdir -p "$CLAUDE_DIR"
            touch "$MARKER_FILE"
            log "Marker file created: $MARKER_FILE"
            return 0
        else
            log "Setup failed (see /tmp/claude-auth-watcher.log)"
            return 1
        fi
    else
        log "claude-setup not found"
        return 1
    fi
}

# If already authenticated, run setup immediately
if is_authenticated; then
    log "Already authenticated. Running setup..."
    run_setup
    exit $?
fi

log "Waiting for Claude authentication..."
log "Timeout: ${TIMEOUT}s, Poll interval: ${POLL_INTERVAL}s"

# Ensure .claude directory exists for watching
mkdir -p "$CLAUDE_DIR"

# Calculate end time
END_TIME=$(($(date +%s) + TIMEOUT))

# Try to use inotifywait if available (efficient event-driven detection)
if command -v inotifywait &>/dev/null; then
    log "Using inotifywait for efficient credential detection"

    while [ "$(date +%s)" -lt "$END_TIME" ]; do
        # Watch for credential file creation/modification
        # Timeout after poll interval to allow periodic authentication check
        if inotifywait -q -t "$POLL_INTERVAL" -e create -e modify "$CLAUDE_DIR" "$HOME" 2>/dev/null; then
            # File change detected, check authentication
            if is_authenticated; then
                run_setup
                exit $?
            fi
        fi

        # Also check periodically in case we missed the event
        if is_authenticated; then
            run_setup
            exit $?
        fi
    done
else
    log "inotifywait not available, using polling (install inotify-tools for efficiency)"

    while [ "$(date +%s)" -lt "$END_TIME" ]; do
        if is_authenticated; then
            run_setup
            exit $?
        fi
        sleep "$POLL_INTERVAL"
    done
fi

log "Timeout reached. Exiting without setup."
log "To run setup manually after authenticating: claude-setup"
exit 0
AUTH_WATCHER_EOF

log_command "Setting claude-auth-watcher permissions" \
    chmod +x /usr/local/bin/claude-auth-watcher

# Create startup directory if it doesn't exist
log_command "Creating container startup directory" \
    mkdir -p /etc/container/startup

# Create startup script that spawns the watcher in the background
command cat > /etc/container/startup/35-claude-auth-watcher.sh << 'STARTUP_WATCHER_EOF'
#!/bin/bash
# Spawn Claude authentication watcher in background
#
# This runs as part of container startup and launches the watcher process
# that will detect when the user authenticates with Claude and automatically
# run claude-setup.

MARKER_FILE="$HOME/.claude/.container-setup-complete"
WATCHER_PID_FILE="/tmp/claude-auth-watcher.pid"

# Skip if setup already completed
if [ -f "$MARKER_FILE" ]; then
    exit 0
fi

# Skip if watcher already running
if [ -f "$WATCHER_PID_FILE" ] && kill -0 "$(cat "$WATCHER_PID_FILE")" 2>/dev/null; then
    exit 0
fi

# Skip if claude-auth-watcher not available
if ! command -v claude-auth-watcher &>/dev/null; then
    exit 0
fi

# Launch watcher in background
echo "[startup] Starting Claude authentication watcher in background..."
nohup claude-auth-watcher > /tmp/claude-auth-watcher.log 2>&1 &
echo $! > "$WATCHER_PID_FILE"
echo "[startup] Watcher started (PID: $(cat "$WATCHER_PID_FILE"))"
STARTUP_WATCHER_EOF

log_command "Setting auth watcher startup script permissions" \
    chmod +x /etc/container/startup/35-claude-auth-watcher.sh

# Create bashrc hook as fallback detection mechanism
command cat > /etc/bashrc.d/90-claude-auth-check.sh << 'BASHRC_AUTH_EOF'
# Claude authentication check (fallback for prompt hook)
#
# This provides a fallback mechanism that checks for Claude authentication
# on every Nth prompt. It's less efficient than the inotifywait watcher but
# ensures setup runs even if the watcher isn't running.

# Only run in interactive shells
[[ $- != *i* ]] && return 0

# Counter for prompt checks (run every 5th prompt)
__CLAUDE_AUTH_CHECK_COUNTER=${__CLAUDE_AUTH_CHECK_COUNTER:-0}

__claude_auth_prompt_check() {
    local marker_file="$HOME/.claude/.container-setup-complete"

    # Skip if setup already completed
    [ -f "$marker_file" ] && return 0

    # Increment counter and check every 5th prompt
    __CLAUDE_AUTH_CHECK_COUNTER=$(( (__CLAUDE_AUTH_CHECK_COUNTER + 1) % 5 ))
    [ "$__CLAUDE_AUTH_CHECK_COUNTER" -ne 0 ] && return 0

    # Check for authentication (token or OAuth)
    if [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
        echo ""
        echo "[claude] Token authentication detected! Running setup in background..."
        (claude-setup && touch "$marker_file") &>/dev/null &
        disown 2>/dev/null || true
        return 0
    fi

    local credentials_file="$HOME/.claude/.credentials.json"
    local config_file="$HOME/.claude.json"

    if [ -f "$credentials_file" ] && grep -q '"claudeAiOauth"' "$credentials_file" 2>/dev/null; then
        echo ""
        echo "[claude] OAuth authentication detected! Running setup in background..."
        (claude-setup && touch "$marker_file") &>/dev/null &
        disown 2>/dev/null || true
        return 0
    fi

    if [ -f "$config_file" ] && grep -q '"oauthAccount"' "$config_file" 2>/dev/null; then
        echo ""
        echo "[claude] OAuth authentication detected! Running setup in background..."
        (claude-setup && touch "$marker_file") &>/dev/null &
        disown 2>/dev/null || true
        return 0
    fi
}

# Add to PROMPT_COMMAND if not already present
if [[ ! "${PROMPT_COMMAND:-}" =~ __claude_auth_prompt_check ]]; then
    PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND; }__claude_auth_prompt_check"
fi
BASHRC_AUTH_EOF

log_command "Setting auth check bashrc permissions" \
    chmod +x /etc/bashrc.d/90-claude-auth-check.sh

# ============================================================================
# Create Claude Environment Configuration
# ============================================================================
log_message "Creating Claude environment configuration..."

mkdir -p /etc/bashrc.d
command cat > /etc/bashrc.d/95-claude-env.sh << 'CLAUDE_ENV_EOF'
#!/bin/bash
# Claude Code CLI environment configuration
# Exports ANTHROPIC_MODEL and ANTHROPIC_AUTH_TOKEN if set

# Export ANTHROPIC_MODEL if set (values: opus, sonnet, haiku)
# This sets the default model for the Claude Code CLI
if [ -n "${ANTHROPIC_MODEL:-}" ]; then
    export ANTHROPIC_MODEL
fi

# Export ANTHROPIC_AUTH_TOKEN if set (for proxy-based authentication)
if [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
    export ANTHROPIC_AUTH_TOKEN
fi
CLAUDE_ENV_EOF

log_command "Setting Claude environment script permissions" \
    chmod +x /etc/bashrc.d/95-claude-env.sh

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
