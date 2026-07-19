#!/usr/bin/env bash
# Seed the INCLUDE_HOST_EVENTS forwarder into the HOST's Claude Code.
#
# The container feature (`lib/features/templates/claude/hooks/claude-host-event.sh`
# + the `claude-setup` settings.json merge) wires the host-event forwarder into a
# CONTAINER's `~/.claude/settings.json`. Worktree golems, however, run in host
# tmux under the HOST's Claude Code, so their hooks fire on the host — where the
# forwarder's topology-aware default already picks `127.0.0.1` (correct) — but
# nothing wires the hook into the HOST `~/.claude/settings.json`, because the
# container merge only runs inside containers (issue #738).
#
# This installer closes that gap for worktree golems. It is the host-side twin of
# the container `claude-setup` merge:
#
#   install  Copy claude-host-event.sh into ~/.claude/hooks/ and jq-merge the
#            8-event hook block into ~/.claude/settings.json — idempotent, and
#            existing hooks (yours or ours) are preserved. Re-running never
#            duplicates.
#   remove   Un-wire the 8-event block (only the commands that point at the
#            copied hook) and delete the copied hook. Leaves unrelated hooks and
#            settings untouched.
#   check    Report whether the hook is installed and how many of the 8 events
#            are currently wired. Read-only. Exit 0 if fully wired, 1 otherwise.
#
# OPT-IN: nothing here runs automatically — you invoke a subcommand explicitly
# (AC3). A host that never runs `install` is never touched.
#
# The jq merge program is duplicated BYTE-IDENTICALLY from `claude-setup` (the
# HOST_EVENT_MAP and the idempotent, preserve-existing reduce) so the host merge
# holds the same invariants as the container merge (AC2). It is intentionally NOT
# extracted to a shared lib: that would touch the in-container runtime path and
# risk an AC4 regression. The source of truth is
# `lib/features/lib/claude/claude-setup` (the "Host Event Forwarding" block); keep
# the HOST_EVENT_MAP and reduce program in sync with it.
#
# Writes go to a temp file ADJACENT to settings.json and are committed with an
# atomic `mv` rename — never a `cat >` truncate, which could corrupt the host's
# primary Claude Code settings on an interrupted write.
#
# Usage: seed-host-events.sh <install|remove|check> [claude-dir]
#   claude-dir defaults to ~/.claude (overridable for testing).
#
# Exit: 0 on success (install/remove/check-wired); 1 on a check that finds the
# forwarder not fully wired; 2 on a usage error (bad/absent subcommand); 3 when a
# required tool (jq) or the staged hook source is unavailable for install.
set -euo pipefail

# --------------------------------------------------------------------------
# Locate the staged forwarder hook relative to this script, so the installer
# works from any cwd and from a bare-repo `sync-host` checkout.
# --------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK_SRC="$REPO_ROOT/lib/features/templates/claude/hooks/claude-host-event.sh"

subcmd="${1:-}"
CLAUDE_DIR="${2:-$HOME/.claude}"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
HOOKS_DIR="$CLAUDE_DIR/hooks"
HOOK_DEST="$HOOKS_DIR/claude-host-event.sh"

# event -> coarse state arg passed to the forwarder. Kept BYTE-IDENTICAL to the
# HOST_EVENT_MAP in `claude-setup` (AC2). PostToolUseFailure is forward-compat.
HOST_EVENT_MAP='{
    "SessionStart": "Idle",
    "UserPromptSubmit": "Working",
    "PreToolUse": "Working",
    "PostToolUse": "Auto",
    "PostToolUseFailure": "ToolFail",
    "Notification": "Waiting",
    "Stop": "Idle",
    "SessionEnd": "Ended"
}'

usage() {
    command echo "Usage: seed-host-events.sh <install|remove|check> [claude-dir]" >&2
}

require_jq() {
    if ! command -v jq >/dev/null 2>&1; then
        command echo "  skipped: jq not available (required to merge $SETTINGS_FILE)" >&2
        exit 3
    fi
}

# Atomically replace $dest with the already-written temp $tmp, preserving $dest's
# existing mode. `mktemp` always creates 0600 and `mv` carries the SOURCE mode
# over, so a bare `mv` would silently tighten a normally-0644 settings.json to
# 0600 on every run — restore the destination's prior mode (default 644) instead.
commit_over() {
    local dest="$1" tmp="$2" mode
    mode="$(/usr/bin/stat -c '%a' "$dest" 2>/dev/null || command echo 644)"
    /usr/bin/mv "$tmp" "$dest"
    /usr/bin/chmod "$mode" "$dest" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# install — copy the hook, jq-merge the 8-event block. Idempotent + preserving.
# ---------------------------------------------------------------------------
do_install() {
    require_jq
    if [ ! -f "$HOOK_SRC" ]; then
        command echo "  skipped: staged forwarder not found at $HOOK_SRC" >&2
        exit 3
    fi

    command mkdir -p "$HOOKS_DIR"
    # Copy (not symlink) so the wired absolute path is independent of the repo
    # checkout location and matches the container $CLAUDE_DIR/hooks layout.
    /usr/bin/install -m 0755 "$HOOK_SRC" "$HOOK_DEST"

    [ -f "$SETTINGS_FILE" ] || command echo '{}' >"$SETTINGS_FILE"

    # Command shape: "<hook-path> <state>". Duplicated byte-identically from the
    # claude-setup reduce: create the per-event array if absent, and append our
    # command hook only when an identical command is not already wired for that
    # event (idempotent; preserves the user's own hooks on these or any events).
    local tmp
    tmp="$(/usr/bin/mktemp "${SETTINGS_FILE}.XXXXXX")"
    if command jq \
        --arg hook "$HOOK_DEST" \
        --argjson map "$HOST_EVENT_MAP" '
        reduce ($map | to_entries[]) as $e (.;
            ($e.key) as $event
            | ($hook + " " + $e.value) as $cmd
            | .hooks[$event] //= []
            | if (.hooks[$event] | any(.[].hooks[]?; .command == $cmd)) then .
              else .hooks[$event] += [{ "hooks": [{ "type": "command", "command": $cmd }] }]
              end)
    ' "$SETTINGS_FILE" >"$tmp" 2>/dev/null; then
        commit_over "$SETTINGS_FILE" "$tmp"
        command echo "  ✓ host event forwarder wired to 8 events -> ${NOTCHBAR_AGENTS_HOST:-127.0.0.1}:${NOTCHBAR_AGENTS_PORT:-7823}"
        command echo "    hook: $HOOK_DEST"
    else
        /usr/bin/rm -f "$tmp"
        command echo "  ⚠ could not wire host event forwarder ($SETTINGS_FILE merge failed)" >&2
        exit 3
    fi
}

# ---------------------------------------------------------------------------
# remove — drop only OUR command hooks (those pointing at the copied hook path)
# from each event, prune events left empty, and delete the copied hook. Unrelated
# hooks and settings are untouched.
# ---------------------------------------------------------------------------
do_remove() {
    require_jq

    if [ -f "$SETTINGS_FILE" ]; then
        local tmp
        tmp="$(/usr/bin/mktemp "${SETTINGS_FILE}.XXXXXX")"
        # For each mapped event: strip hook-entries whose command starts with our
        # copied hook path, drop entries whose inner hooks array became empty, then
        # remove the event key entirely if no entries remain. `del(.hooks)` when the
        # object empties keeps settings.json clean.
        if command jq \
            --arg hook "$HOOK_DEST" \
            --argjson map "$HOST_EVENT_MAP" '
            reduce ($map | keys_unsorted[]) as $event (.;
                if (.hooks[$event]?) then
                    .hooks[$event] = ([ .hooks[$event][]
                        | .hooks = [ .hooks[]? | select((.command // "") | startswith($hook) | not) ]
                        | select((.hooks | length) > 0) ])
                    | (if (.hooks[$event] | length) == 0 then del(.hooks[$event]) else . end)
                else . end)
            | (if (.hooks? // {}) == {} then del(.hooks) else . end)
        ' "$SETTINGS_FILE" >"$tmp" 2>/dev/null; then
            commit_over "$SETTINGS_FILE" "$tmp"
            command echo "  ✓ un-wired host event forwarder from $SETTINGS_FILE"
        else
            /usr/bin/rm -f "$tmp"
            command echo "  ⚠ could not un-wire ($SETTINGS_FILE merge failed) — hook copy left in place" >&2
            exit 3
        fi
    else
        command echo "  settings.json absent — nothing to un-wire"
    fi

    if [ -f "$HOOK_DEST" ]; then
        /usr/bin/rm -f "$HOOK_DEST"
        command echo "  ✓ removed $HOOK_DEST"
    fi
}

# ---------------------------------------------------------------------------
# check — read-only report. Exit 0 only if the hook is copied AND all 8 events
# are wired; else exit 1.
# ---------------------------------------------------------------------------
do_check() {
    require_jq

    local hook_present="no"
    [ -f "$HOOK_DEST" ] && hook_present="yes"

    # Count how many of the 8 mapped events have our exact command wired. Bind the
    # root object to $root so each map entry can look up its own event under it.
    local wired=0
    if [ -f "$SETTINGS_FILE" ]; then
        wired="$(command jq -r \
            --arg hook "$HOOK_DEST" \
            --argjson map "$HOST_EVENT_MAP" '
            . as $root
            | [ ($map | to_entries[])
                | ($hook + " " + .value) as $cmd
                | .key as $event
                | select(($root.hooks[$event]? // []) | any(.[].hooks[]?; .command == $cmd)) ]
            | length
        ' "$SETTINGS_FILE" 2>/dev/null || command echo 0)"
    fi

    command echo "  hook copied:  $hook_present ($HOOK_DEST)"
    command echo "  events wired: $wired / 8 ($SETTINGS_FILE)"
    if [ "$hook_present" = "yes" ] && [ "$wired" = "8" ]; then
        command echo "  ✓ host event forwarding is fully installed"
        return 0
    fi
    command echo "  ✗ host event forwarding is not fully installed (run: seed-host-events.sh install)"
    return 1
}

case "$subcmd" in
    install) do_install ;;
    remove) do_remove ;;
    check) do_check ;;
    "")
        command echo "seed-host-events.sh: missing subcommand" >&2
        usage
        exit 2
        ;;
    *)
        command echo "seed-host-events.sh: unknown subcommand '$subcmd'" >&2
        usage
        exit 2
        ;;
esac
