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
    if [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ] || [ -s /dev/shm/anthropic-auth-token ]; then
        echo ""
        echo "[claude] Token authentication detected! Running setup in background..."
        (claude-setup && touch "$marker_file") &>/dev/null &
        disown 2>/dev/null || true
        return 0
    fi

    local credentials_file="$HOME/.claude/.credentials.json"
    local config_file="$HOME/.claude.json"

    if [ -f "$credentials_file" ] && command grep -q '"claudeAiOauth"' "$credentials_file" 2>/dev/null; then
        echo ""
        echo "[claude] OAuth authentication detected! Running setup in background..."
        (claude-setup && touch "$marker_file") &>/dev/null &
        disown 2>/dev/null || true
        return 0
    fi

    if [ -f "$config_file" ] && command grep -q '"oauthAccount"' "$config_file" 2>/dev/null; then
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
