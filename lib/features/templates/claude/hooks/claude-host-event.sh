#!/bin/bash
# Claude Code -> host monitor event forwarder (INCLUDE_HOST_EVENTS).
#
# Forwards each Claude Code hook event to a host-side agent monitor's local HTTP
# bridge (e.g. Bartender's Top Shelf: POST /event on 127.0.0.1:7823) so agents
# running INSIDE a container are visible in the host menu-bar UI. From a
# container the bridge is reached via `host.docker.internal`; override with
# NOTCHBAR_AGENTS_HOST / NOTCHBAR_AGENTS_PORT (Top Shelf's documented remote-agent
# knobs) when the monitor listens elsewhere.
#
# This is a golem-identity-stamping adaptation of Top Shelf's stock claude hook:
# the host bridge keys sessions SOLELY on `session_id`, so we override it with a
# stable `<project>-golem-<N>` key (and a human-readable `title`) so every golem
# is a distinct, legible row in the host UI instead of an opaque Claude session
# id. The container-internal `pid`/`terminal` fields the stock hook sends are
# meaningless across the boundary (display-only on the host side) and are
# omitted.
#
# Wired into ~/.claude/settings.json by `claude-setup` when
# INCLUDE_HOST_EVENTS=true. Invoked as:
#     claude-host-event.sh <STATE>
# with the Claude Code hook JSON on stdin. STATE is the coarse per-event label
# (Idle/Working/Auto/Waiting/ToolFail/Ended) chosen by the settings.json wiring;
# the python block below refines it from the hook payload.
#
# Contract: NEVER block or fail the agent — every path exits 0, the POST is
# fire-and-forget (backgrounded for non-terminal events), and a missing
# curl/python3 degrades to a best-effort minimal payload.
set -u

STATE="${1:-Working}"

# Default host is topology-aware. Worktree golems run in host tmux (the common,
# lighter-weight case) — their hooks fire ON the host, where the bridge is
# loopback. Container/devcontainer golems reach the host via host.docker.internal.
# NOTCHBAR_AGENTS_HOST overrides both (e.g. a monitor on another machine).
default_host="127.0.0.1"
if [ -f /.dockerenv ] || [ -n "${AGENT_ID:-}" ] || command grep -qaE '(docker|containerd|kubepods)' /proc/1/cgroup 2>/dev/null; then
    default_host="host.docker.internal"
fi
HOST="${NOTCHBAR_AGENTS_HOST:-$default_host}"
PORT="${NOTCHBAR_AGENTS_PORT:-7823}"
HOOK_JSON=$(command cat)

# ---------------------------------------------------------------------------
# Golem identity — same resolution order as the orchestrate Notification hook
# (.claude/hooks/golem-notify.sh), so the two feeds agree on who a golem is:
#   1. $GOLEM_ID (stamped at launch by the workflow plugin; worktree golems)
#   2. git worktree-root basename: issue-N -> golem-N (cwd-independent)
#   3. $AGENT_ID (container golems, e.g. agentNN from agent-entrypoint.sh)
#   4. placeholder
# ---------------------------------------------------------------------------
golem=""
case "${GOLEM_ID:-}" in
    golem-*) golem="$GOLEM_ID" ;;
esac
if [ -z "$golem" ]; then
    base="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")"
    case "$base" in
        issue-*) golem="golem-${base#issue-}" ;;
        golem-*) golem="$base" ;;
        *)
            case "${AGENT_ID:-}" in
                ?*) golem="$AGENT_ID" ;;
                *) golem="golem-?" ;;
            esac
            ;;
    esac
fi

# Project name: explicit $PROJECT_NAME (stamped into container golems) else the
# repo/worktree basename's parent-project shape, else the toplevel basename.
project="${PROJECT_NAME:-}"
if [ -z "$project" ]; then
    project="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")"
    # Strip an issue-/golem- worktree suffix so sibling golems share a project.
    case "$project" in
        issue-* | golem-*) project="$(basename "$(dirname "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")")" ;;
    esac
fi
[ -z "$project" ] && project="project"

# Build the payload. Prefer python3 (correct JSON + state refinement from the
# hook body, mirroring Top Shelf's mapping); fall back to a minimal hand-rolled
# object so the event still registers if python3 is unavailable.
payload=""
if command -v python3 >/dev/null 2>&1; then
    payload=$(
        STATE="$STATE" HOOK_JSON="$HOOK_JSON" PROJECT="$project" GOLEM="$golem" \
            python3 - <<'PY' 2>/dev/null
import json, os, sys

try:
    d = json.loads(os.environ.get("HOOK_JSON") or "{}")
except Exception:
    d = {}

state = os.environ.get("STATE") or "Working"
# Refine coarse per-event states from the hook payload, matching Top Shelf:
if state == "Auto":
    # PostToolUse: a tool completed, agent is still working the turn.
    state = "Working"
elif state == "ToolFail":
    # A user interrupt reads as Idle; a genuine tool failure keeps Working.
    state = "Idle" if d.get("is_interrupt") is True else "Working"
elif state == "Waiting":
    # Notification fires for both permission gates AND transient idles; only a
    # permission gate is a real "waiting for a human" state.
    msg = (d.get("message") or "").lower()
    state = "Waiting" if "permission" in msg else "Idle"

project = os.environ.get("PROJECT") or "project"
golem = os.environ.get("GOLEM") or "golem-?"
# session_id is the host bridge's SOLE primary key -> make it the stable golem
# identity so each agent is one persistent, named row on the host.
session_id = "{}-{}".format(project, golem)

title = ""
if d.get("hook_event_name") == "UserPromptSubmit":
    prompt = d.get("prompt")
    if isinstance(prompt, str) and prompt.strip():
        title = prompt.strip()[:120]
label = "{} · {}".format(project, golem)
title = "{} · {}".format(label, title) if title else label

sys.stdout.write(json.dumps({
    "state": state,
    "agent": "Claude",
    "event": d.get("hook_event_name") or "",
    "session_id": session_id,
    "cwd": d.get("cwd") or "",
    "title": title,
}))
PY
    )
fi

if [ -z "${payload:-}" ]; then
    # python3 absent or errored: minimal but valid — session_id still keys the
    # golem so state at least registers/clears on the host.
    payload="{\"state\":\"${STATE}\",\"agent\":\"Claude\",\"session_id\":\"${project}-${golem}\"}"
fi

url="http://${HOST}:${PORT}/event"
if [ "$STATE" = "Ended" ]; then
    # Terminal event: send synchronously (short timeout) so the session is
    # deregistered before the shell tears down.
    curl -s -m 2 -X POST "$url" -H 'Content-Type: application/json' \
        --data-raw "$payload" >/dev/null 2>&1
else
    curl -s -m 1 -X POST "$url" -H 'Content-Type: application/json' \
        --data-raw "$payload" >/dev/null 2>&1 &
fi

exit 0
