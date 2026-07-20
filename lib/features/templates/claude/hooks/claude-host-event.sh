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
# Session identity — same resolution order as the orchestrate Notification hook
# (.claude/hooks/golem-notify.sh), so the two feeds agree on who a session is:
#   1. $GOLEM_ID (stamped at launch by the workflow plugin; worktree golems)
#   2. git worktree-root basename: issue-N -> golem-N (cwd-independent)
#   3. $AGENT_ID (container golems, e.g. agentNN from agent-entrypoint.sh)
#   4. $CLAUDE_SESSION_ROLE=orchestrator (#750) — a non-golem session that is
#      driving a fleet of golems via /orchestrate. It has no stable unique id
#      (like a golem does), so it is a LABELED VARIANT of `primary`: the python
#      block below differentiates it per-tab by the Claude-native session_id
#      exactly as it does `primary`, only the label differs. This is the
#      CONSUME side of a librarian-emitted marker (the /orchestrate skill
#      exports it); until the emit side ships this arm is simply never taken.
#   5. `primary` — a non-golem interactive session with no orchestrator marker:
#      a human working directly in the main checkout. This is NOT a golem, so it
#      must not carry the `golem-?` placeholder (which reads as a broken golem
#      on the host). The python block below differentiates concurrent primary
#      sessions (multiple shell tabs) by the Claude-native session_id so they
#      don't collide on one host row.
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
                *)
                    # Orchestrator marker classifies a marked session before the
                    # bare `primary` fallback; unset/unknown falls through (#750).
                    case "${CLAUDE_SESSION_ROLE:-}" in
                        orchestrator) golem="orchestrator" ;;
                        *) golem="primary" ;;
                    esac
                    ;;
            esac
            ;;
    esac
fi

# Project name: explicit $PROJECT_NAME (stamped into container golems) else the
# ROOT checkout's basename. Resolve it via the git COMMON dir, whose parent is
# the main checkout — for a worktree golem at <root>/.worktrees/issue-N this is
# `<root>` (e.g. `containers`). The old show-toplevel path resolved a worktree to
# its parent dir `.worktrees` instead of the real project, so sibling golems
# surfaced on the host under `.worktrees` rather than the project name.
#
# `git rev-parse --git-common-dir` returns a RELATIVE path (e.g. `../../.git`)
# when the hook fires from a SUBDIRECTORY of a plain/main checkout — which a
# primary session commonly does (a tool call cd'd into a crate/lib dir). The
# main checkout's parent must therefore be resolved with a real `cd … && pwd`
# so the `..` segments canonicalize; string-only dirname/basename would leave
# `project` as the literal `..`. A linked worktree's `.git` file anchors an
# ABSOLUTE gitdir at any depth, so this also covers the golem case unchanged.
project="${PROJECT_NAME:-}"
if [ -z "$project" ]; then
    common_dir="$(git rev-parse --git-common-dir 2>/dev/null || true)"
    root=""
    if [ -n "$common_dir" ]; then
        # Canonicalize <common_dir>/.. (the checkout root) via an actual cd.
        root="$(cd "$(dirname "$common_dir")" 2>/dev/null && pwd)"
    fi
    [ -z "$root" ] && root="$(pwd)"
    project="$(basename "$root")"
fi
[ -z "$project" ] && project="project"

# Worktree root for this session — the golem's per-issue pipeline state file
# (`.claude/memory/tmp/next-issue-{N}.json`) lives under it. Resolved HERE (not
# in python) so the python block stays git-free / pure-stdlib, mirroring the
# existing split where the shell does all git resolution. Best-effort: an empty
# result falls back to $(pwd) and the phase lookup simply finds nothing.
toplevel="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -z "$toplevel" ] && toplevel="$(pwd)"

# Build the payload. Prefer python3 (correct JSON + state refinement from the
# hook body, mirroring Top Shelf's mapping); fall back to a minimal hand-rolled
# object so the event still registers if python3 is unavailable.
payload=""
if command -v python3 >/dev/null 2>&1; then
    payload=$(
        STATE="$STATE" HOOK_JSON="$HOOK_JSON" PROJECT="$project" GOLEM="$golem" \
            TOPLEVEL="$toplevel" \
            python3 - <<'PY' 2>/dev/null
import glob, json, os, re, sys

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
golem = os.environ.get("GOLEM") or "primary"
# session_id is the host bridge's SOLE primary key -> make it the stable session
# identity so each agent is one persistent, named row on the host.
#
# A golem has a stable, unique id already (golem-N / AGENT_ID), so its key is
# just "{project}-{golem}". A `primary` (human) or `orchestrator` (#750) session
# has no such id, and EVERY such session in a repo would otherwise collapse to
# the same "{project}-{role}" key -> concurrent shell tabs clobber one host row.
# Differentiate them by the Claude-native session_id (unique per session): key
# each as "{project}-{role}-{short}". Fall back to the bare "{project}-{role}"
# when the payload carries no session_id (still valid, just non-differentiated).
if golem in ("primary", "orchestrator"):
    cc_session = d.get("session_id")
    short = cc_session[:8] if isinstance(cc_session, str) and cc_session.strip() else ""
    label = "{}-{}".format(project, golem)
    session_id = "{}-{}".format(label, short) if short else label
else:
    label = "{}-{}".format(project, golem)
    session_id = label

# Activity line. A golem in the /next-issue -> /ship-issue pipeline persists a
# `phase` to <worktree>/.claude/memory/tmp/next-issue-{N}.json; surface THAT as
# the activity ("Planning"/"Building"/...) instead of the launch-prompt text,
# which for a golem degrades to the issue reference already in `golem`. Read on
# every event (not just UserPromptSubmit) so the line is a live phase readout.
PHASE_VERBS = {
    "select": "Selecting",
    "plan": "Planning",
    "implement": "Building",
    "ship": "Shipping",
}


def resolve_phase(toplevel, golem):
    """Friendly verb for the golem's current pipeline phase, or "".

    Best-effort by contract: a primary/orchestrator session, a missing/malformed
    state file, or an unknown phase all yield "" so the caller falls back to the
    prompt-derived title. Never raises.
    """
    # Neither a human `primary` nor an `orchestrator` (#750) is in the per-issue
    # pipeline, so neither carries a phase verb — a stray state file in the
    # checkout must not paint a false phase on them.
    if not toplevel or golem in ("primary", "orchestrator"):
        return ""
    tmpdir = os.path.join(toplevel, ".claude", "memory", "tmp")
    candidate = None
    m = re.match(r"golem-(\d+)$", golem)  # golem-N -> next-issue-N.json
    if m:
        p = os.path.join(tmpdir, "next-issue-{}.json".format(m.group(1)))
        if os.path.isfile(p):
            candidate = p
    if candidate is None and m is None:
        # AGENT_ID container golems have no issue number in the id; fall back to
        # the sole per-issue state file if exactly one exists (the singleton
        # next-issue-queue.json is not a per-issue file — exclude it). This is
        # gated on `m is None` (no issue number in the id): a golem-N whose own
        # next-issue-N.json is simply absent must NOT borrow an unrelated issue's
        # phase from a stray file left in the same worktree — that would show a
        # wrong phase, the exact confusion this feature removes.
        files = [
            f
            for f in glob.glob(os.path.join(tmpdir, "next-issue-*.json"))
            if not f.endswith("next-issue-queue.json")
        ]
        if len(files) == 1:
            candidate = files[0]
    if not candidate:
        return ""
    try:
        with open(candidate) as fh:
            phase = json.load(fh).get("phase")
    except Exception:
        return ""
    return PHASE_VERBS.get(phase, "")


detail = resolve_phase(os.environ.get("TOPLEVEL"), golem)
if not detail and d.get("hook_event_name") == "UserPromptSubmit":
    prompt = d.get("prompt")
    if isinstance(prompt, str) and prompt.strip():
        detail = prompt.strip()[:120]
title_label = "{} · {}".format(project, golem)
title = "{} · {}".format(title_label, detail) if detail else title_label

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
    # session so state at least registers/clears on the host. Without python we
    # can't parse the payload's native session_id, so a primary session uses the
    # bare "${project}-primary" key (non-differentiated across tabs, but valid).
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
