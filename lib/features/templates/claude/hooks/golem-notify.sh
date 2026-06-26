#!/usr/bin/env bash
# Notification hook for the orchestrate golem flow.
#
# Claude Code fires the `Notification` hook when a session is awaiting a
# permission decision or other input. For a golem (an interactive
# `/next-issue --auto` session running in tmux under `auto` permission mode)
# that is exactly the "BLOCKED — needs a human" signal the orchestrator must
# surface. The golem's TUI paints an alternate screen buffer, so it cannot be
# scraped live; this hook is the TTY-free channel instead.
#
# It appends one JSON line to a central feed under the MAIN checkout's
# .worktrees/.status/feed.jsonl (resolved via the shared git common dir so it
# works from inside a worktree), which `just golems` reads. It must NEVER block
# the golem: any error is swallowed and it always exits 0.
#
# Input  (stdin):  Notification hook JSON, e.g. {"message":"...", ...}
# Output (feed):   {"ts","golem","event":"blocked","message"}
set -uo pipefail

# Resolve the main repo root even when invoked from a worktree:
# git-common-dir points at <main>/.git, whose parent is the main checkout.
common_dir="$(git rev-parse --git-common-dir 2>/dev/null || true)"
if [ -z "$common_dir" ]; then
    exit 0 # not in a git repo — nothing to record, never block the golem
fi
case "$common_dir" in
    /*) ;; # already absolute
    *) common_dir="$(pwd)/$common_dir" ;;
esac
root="$(/usr/bin/dirname "$common_dir")"
status_dir="$root/.worktrees/.status"
feed="$status_dir/feed.jsonl"

# Read the Notification payload; tolerate missing jq or a non-JSON body.
payload="$(/bin/cat 2>/dev/null || true)"
message=""
if command -v jq >/dev/null 2>&1; then
    message="$(printf '%s' "$payload" | jq -r '.message // empty' 2>/dev/null || true)"
fi
[ -z "$message" ] && message="awaiting permission decision"

# Derive the golem id: prefer the tmux session name (golem-N), else the
# worktree dir basename (issue-N -> golem-N), else a placeholder.
golem=""
if [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
    golem="$(tmux display-message -p '#S' 2>/dev/null || true)"
fi
if [ -z "$golem" ]; then
    base="$(/usr/bin/basename "$(pwd)")"
    case "$base" in
        issue-*) golem="golem-${base#issue-}" ;;
        golem-*) golem="$base" ;;
        *) golem="golem-?" ;;
    esac
fi

ts="$(/usr/bin/date -u +%FT%TZ)"

# Append one feed line. Prefer jq for correct escaping; fall back to a
# best-effort literal if jq is unavailable.
/usr/bin/mkdir -p "$status_dir" 2>/dev/null || exit 0
if command -v jq >/dev/null 2>&1; then
    jq -cn --arg ts "$ts" --arg golem "$golem" --arg message "$message" \
        '{ts: $ts, golem: $golem, event: "blocked", message: $message}' \
        >>"$feed" 2>/dev/null || true
else
    printf '{"ts":"%s","golem":"%s","event":"blocked","message":"%s"}\n' \
        "$ts" "$golem" "${message//\"/\\\"}" >>"$feed" 2>/dev/null || true
fi

exit 0
