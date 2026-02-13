#!/bin/bash
# MCP Server Registry - Maps short names to packages and configuration
#
# Description:
#   Provides a registry of optional MCP servers that can be installed via
#   the CLAUDE_EXTRA_MCPS build argument or runtime environment variable.
#   Each entry maps a short name to its package and claude mcp add arguments.
#   Supports both npm packages (via npx) and Python packages (via uvx).
#
# Usage:
#   source mcp-registry.sh
#   mcp_registry_get_npm_package "brave-search"  # @modelcontextprotocol/server-brave-search
#   mcp_registry_get_package_type "brave-search"  # npm
#   mcp_registry_get_add_args "brave-search"      # -t stdio brave-search -- npx -y ...
#   mcp_registry_get_env_docs "brave-search"      # BRAVE_API_KEY
#   mcp_registry_is_registered "brave-search"      # returns 0 (true)
#
# Adding a new MCP server:
#   Add a case to each of the five functions below. No other files need changes.
#

# Get the npm package name for an MCP server
# Usage: mcp_registry_get_npm_package <name>
# Returns: npm package name on stdout, exit 1 if not registered
mcp_registry_get_npm_package() {
    local name="${1:-}"
    case "$name" in
        brave-search)
            echo "@modelcontextprotocol/server-brave-search"
            ;;
        fetch)
            echo "@modelcontextprotocol/server-fetch"
            ;;
        memory)
            echo "@modelcontextprotocol/server-memory"
            ;;
        sequential-thinking)
            echo "@modelcontextprotocol/server-sequential-thinking"
            ;;
        git)
            echo "@modelcontextprotocol/server-git"
            ;;
        sentry)
            echo "@sentry/mcp-server"
            ;;
        perplexity)
            echo "@perplexity-ai/mcp-server"
            ;;
        kagi)
            echo "kagimcp"
            ;;
        *)
            return 1
            ;;
    esac
}

# Get the package type for an MCP server (npm or uvx)
# Usage: mcp_registry_get_package_type <name>
# Returns: "npm" or "uvx" on stdout, exit 1 if not registered
mcp_registry_get_package_type() {
    local name="${1:-}"
    case "$name" in
        kagi)
            echo "uvx"
            ;;
        brave-search|fetch|memory|sequential-thinking|git|sentry|perplexity)
            echo "npm"
            ;;
        *)
            return 1
            ;;
    esac
}

# Get the claude mcp add arguments for an MCP server
# Usage: mcp_registry_get_add_args <name>
# Returns: arguments for claude mcp add on stdout, exit 1 if not registered
# Note: The server name is included as part of the args
mcp_registry_get_add_args() {
    local name="${1:-}"
    case "$name" in
        brave-search)
            echo "-t stdio brave-search -e BRAVE_API_KEY=\${BRAVE_API_KEY} -- npx -y @modelcontextprotocol/server-brave-search"
            ;;
        fetch)
            echo "-t stdio fetch -- npx -y @modelcontextprotocol/server-fetch"
            ;;
        memory)
            echo "-t stdio memory -- npx -y @modelcontextprotocol/server-memory"
            ;;
        sequential-thinking)
            echo "-t stdio sequential-thinking -- npx -y @modelcontextprotocol/server-sequential-thinking"
            ;;
        git)
            echo "-t stdio git -- npx -y @modelcontextprotocol/server-git"
            ;;
        sentry)
            echo "-t stdio sentry -e SENTRY_ACCESS_TOKEN=\${SENTRY_ACCESS_TOKEN} -- npx -y @sentry/mcp-server"
            ;;
        perplexity)
            echo "-t stdio perplexity -e PERPLEXITY_API_KEY=\${PERPLEXITY_API_KEY} -- npx -y @perplexity-ai/mcp-server"
            ;;
        kagi)
            echo "-t stdio kagi -e KAGI_API_KEY=\${KAGI_API_KEY} -- uvx kagimcp"
            ;;
        *)
            return 1
            ;;
    esac
}

# Get documentation of required environment variables for an MCP server
# Usage: mcp_registry_get_env_docs <name>
# Returns: env var documentation on stdout (empty string if none required)
mcp_registry_get_env_docs() {
    local name="${1:-}"
    case "$name" in
        brave-search)
            echo "BRAVE_API_KEY"
            ;;
        fetch)
            echo ""
            ;;
        memory)
            echo "MEMORY_FILE_PATH (optional)"
            ;;
        sequential-thinking)
            echo ""
            ;;
        git)
            echo ""
            ;;
        sentry)
            echo "SENTRY_ACCESS_TOKEN"
            ;;
        perplexity)
            echo "PERPLEXITY_API_KEY"
            ;;
        kagi)
            echo "KAGI_API_KEY"
            ;;
        *)
            echo ""
            ;;
    esac
}

# Check if an MCP server name is registered
# Usage: mcp_registry_is_registered <name>
# Returns: 0 if registered, 1 if not
mcp_registry_is_registered() {
    local name="${1:-}"
    mcp_registry_get_npm_package "$name" >/dev/null 2>&1
}

# List all registered MCP server names
# Usage: mcp_registry_list
# Returns: space-separated list of registered names
mcp_registry_list() {
    echo "brave-search fetch memory sequential-thinking git sentry perplexity kagi"
}
