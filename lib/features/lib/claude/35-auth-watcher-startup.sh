#!/bin/bash
# Spawn Claude authentication watcher in background
#
# This runs as part of container startup and launches the watcher process
# that will detect when the user authenticates with Claude and automatically
# run claude-setup.
#
# The claude-setup this watcher eventually runs may race the one that
# 30-first-startup.sh backgrounds. That is safe by construction: claude-setup
# holds an flock on /tmp/claude-setup.lock for its whole run (#784), so the two
# serialize rather than interleaving their ~/.claude/settings.json
# read-modify-write. Both launch paths are intentional — see the note in
# 30-first-startup.sh.

MARKER_FILE="$HOME/.claude/.container-setup-complete"
WATCHER_PID_FILE="/tmp/claude-auth-watcher.pid"

# Skip if setup already completed
if [ -f "$MARKER_FILE" ]; then
    exit 0
fi

# Skip if watcher already running
if [ -f "$WATCHER_PID_FILE" ] && kill -0 "$(command cat "$WATCHER_PID_FILE")" 2>/dev/null; then
    exit 0
fi

# Skip if claude-auth-watcher not available
if ! command -v claude-auth-watcher &>/dev/null; then
    exit 0
fi

# Launch watcher in background
echo "[startup] Starting Claude authentication watcher in background..."
nohup claude-auth-watcher >/tmp/claude-auth-watcher.log 2>&1 &
echo $! >"$WATCHER_PID_FILE"
echo "[startup] Watcher started (PID: $(command cat "$WATCHER_PID_FILE"))"
