#!/bin/bash
# Bootstrap a Zed custom-agent ("AI panel") entry that points at the container's
# provider-neutral ACP launch wrapper, so the agent uses whatever Anthropic
# credentials the container already has instead of prompting for sign-in.
#
# Why: Zed launches its Claude Code ACP agent directly, bypassing the
# interactive `claude` bash wrapper that re-injects the token 95-claude-env.sh
# strips from the environment. The wrapper (/usr/local/bin/claude-acp-launch)
# bridges that gap; this script wires Zed to it via agent_servers.
#
# Conditional + provider-agnostic:
#   - No-op unless the container actually has Anthropic credentials (any form:
#     token, API key, or an OP_ANTHROPIC_*_REF to be resolved). With none
#     present, the built-in agent's own sign-in is the correct behavior, so we
#     write nothing.
#   - No-op unless the wrapper is installed.
#   - The agent label and command are provider-neutral (no assumption about
#     which proxy or key type is in use). No secret is ever written to
#     settings.json — only the wrapper path; the wrapper resolves creds at launch.
#
# Runs in first-startup, as the container user. VS Code / JetBrains ignore
# ~/.config/zed/, so this is a no-op outside Zed.

set -euo pipefail

WRAPPER="/usr/local/bin/claude-acp-launch"
OP_CACHE="/dev/shm/op-secrets-cache"
TOKEN_FILE="/dev/shm/anthropic-auth-token"
AGENT_LABEL="Claude Code (container)"

ZED_SETTINGS_DIR="${HOME}/.config/zed"
ZED_SETTINGS_FILE="${ZED_SETTINGS_DIR}/settings.json"

# --- Guard 1: the wrapper must be installed (dev-tools + claude features) ---
if [ ! -x "$WRAPPER" ]; then
    exit 0
fi

# --- Guard 2: detect whether ANY Anthropic credential is present ---
# Cover the live env, the stripped-token shm file, the resolved secrets cache,
# and as-yet-unresolved OP_ANTHROPIC_*_REF references.
have_creds=false
if [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ] || [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    have_creds=true
elif [ -r "$TOKEN_FILE" ] && [ -s "$TOKEN_FILE" ]; then
    have_creds=true
elif [ -r "$OP_CACHE" ] && command grep -qE '^export ANTHROPIC_(AUTH_TOKEN|API_KEY)=' "$OP_CACHE"; then
    have_creds=true
else
    # Any OP_ANTHROPIC_*_REF in the environment means creds will resolve at runtime.
    while IFS='=' read -r _name _; do
        case "$_name" in
            OP_ANTHROPIC_*_REF)
                have_creds=true
                break
                ;;
        esac
    done < <(env)
fi

if [ "$have_creds" != "true" ]; then
    echo "[zed-agent-config] no Anthropic credentials detected; leaving the AI panel to its own sign-in."
    exit 0
fi

# --- The agent_servers fragment we want present ---
# Strict JSON (no comments): this file is jq-merged by sibling scripts, and jq
# can't parse JSONC. The entry is a custom Claude Code ACP agent ("AI panel")
# wired to this container's Anthropic credentials via the launch wrapper; the
# wrapper re-injects the token/base-URL/model kept out of the environment for
# security, so no secret is stored in this file. Provider-agnostic.
read -r -d '' AGENT_BLOCK <<JSON || true
{
  "agent_servers": {
    "${AGENT_LABEL}": {
      "type": "custom",
      "command": "${WRAPPER}",
      "args": [],
      "env": {}
    }
  }
}
JSON

# --- No existing settings: write a fresh file with just the agent block ---
if [ ! -f "$ZED_SETTINGS_FILE" ]; then
    mkdir -p "$ZED_SETTINGS_DIR"
    printf '%s\n' "$AGENT_BLOCK" >"$ZED_SETTINGS_FILE"
    echo "[zed-agent-config] wrote ${ZED_SETTINGS_FILE} with the '${AGENT_LABEL}' agent."
    exit 0
fi

# --- Existing settings: merge with jq if it parses as strict JSON ---
# Zed settings.json commonly contains // comments (e.g. the LSP bootstrap this
# container also ships), which jq cannot parse. If the file is strict JSON we
# merge in place; otherwise we leave it untouched and print the block to paste.
if command -v jq >/dev/null 2>&1 && jq -e . "$ZED_SETTINGS_FILE" >/dev/null 2>&1; then
    if jq -e --arg label "$AGENT_LABEL" '.agent_servers[$label] != null' \
        "$ZED_SETTINGS_FILE" >/dev/null 2>&1; then
        echo "[zed-agent-config] '${AGENT_LABEL}' already present in ${ZED_SETTINGS_FILE}; leaving it."
        exit 0
    fi
    tmp="${ZED_SETTINGS_FILE}.tmp"
    if jq --arg label "$AGENT_LABEL" --arg cmd "$WRAPPER" '
        .agent_servers[$label] = {type: "custom", command: $cmd, args: [], env: {}}
    ' "$ZED_SETTINGS_FILE" >"$tmp" 2>/dev/null; then
        mv "$tmp" "$ZED_SETTINGS_FILE"
        echo "[zed-agent-config] merged the '${AGENT_LABEL}' agent into ${ZED_SETTINGS_FILE}."
        exit 0
    fi
    command rm -f "$tmp"
fi

# --- Fallback: can't safely merge (comments / invalid JSON) — print for paste ---
echo "[zed-agent-config] ${ZED_SETTINGS_FILE} exists and could not be parsed as strict JSON"
echo "  (it likely contains // comments). Add this agent manually to use the"
echo "  container's Anthropic credentials in the AI panel:"
echo "$AGENT_BLOCK" | command sed 's/^/    /'
exit 0
