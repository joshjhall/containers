#!/bin/bash
# Claude Code CLI environment configuration

# Export ANTHROPIC_MODEL if set (values: opus, sonnet, haiku)
# This sets the default model for the Claude Code CLI
if [ -n "${ANTHROPIC_MODEL:-}" ]; then
    export ANTHROPIC_MODEL
fi

# Secure ANTHROPIC_AUTH_TOKEN: capture to /dev/shm file, remove from env.
# Token is injected into only the claude CLI process via the wrapper below.
if [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
    printf '%s' "$ANTHROPIC_AUTH_TOKEN" > /dev/shm/anthropic-auth-token
    chmod 600 /dev/shm/anthropic-auth-token
    unset ANTHROPIC_AUTH_TOKEN
fi

# Wrapper: inject token from secure file into claude process only
claude() {
    local _old_xtrace
    _old_xtrace=$(set +o | command grep xtrace)
    set +x
    local _token
    _token=$(command cat /dev/shm/anthropic-auth-token 2>/dev/null) || true
    eval "$_old_xtrace"
    if [ -n "$_token" ]; then
        ANTHROPIC_AUTH_TOKEN="$_token" command claude "$@"
    else
        command claude "$@"
    fi
}
