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
