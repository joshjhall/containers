#!/bin/bash
# Claude Code first-startup wrapper
# Calls claude-setup to configure plugins and MCP servers
#
# This script runs once on first container startup. It:
# - Launches claude-setup in the background so it doesn't block the entrypoint
# - The auth-watcher (35-auth-watcher-startup.sh) also handles deferred setup
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

# Run claude-setup in the background to avoid blocking container startup (~48s).
# The auth-watcher will also detect authentication and run setup if this
# initial attempt fails (e.g. not yet authenticated).
if command -v claude-setup &>/dev/null; then
    (
        claude-setup --force >/tmp/claude-first-setup.log 2>&1 || true
    ) &
    disown
    echo "[first-startup] claude-setup launched in background (PID: $!)"
fi
