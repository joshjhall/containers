---
name: host-monitor-state-forwarding-735
description: Concept + blocking research for forwarding container golem state to host menu-bar monitors (issue #735)
metadata:
  type: project
---

Issue **#735** (`status/blocked`, component/stibbons + component/observability):
forward Claude Code agent state (working / waiting / gated / errored / idle)
from container/devcontainer golems **up to the host** so host menu-bar monitors
(so-agentbar / Agent Bar; Bartender only *arranges* icons another app
publishes) show one cross-project command-center view.

**MONITOR IDENTIFIED (2026-07-16, see #735 comment):** the host app is **Top
Shelf** (AI-agent feature in Bartender). Mechanism = **HTTP push**, NOT
file-watch. It runs a local bridge on `127.0.0.1:7823` (`POST /event`,
`GET /health`); their Claude hook curls a JSON payload per hook event. This
INVERTS the transport: HTTP crosses container→host natively, no mounts. Top
Shelf explicitly supports containers via `NOTCHBAR_AGENTS_HOST` /
`NOTCHBAR_AGENTS_PORT` env in the hook. Verified from a golem container:
`host.docker.internal` → 192.168.185.254; curl + python3 in the image. So the
integration for Top Shelf = install their hook + export
`NOTCHBAR_AGENTS_HOST=host.docker.internal` — a small extension of
`lib/features/claude-code-setup.sh:253-262` (already jq-merges into
`~/.claude/settings.json`). Top Shelf IS the aggregator; stibbons doesn't build a
collector for this path. Pluggable-sink still matters for OTHER monitors that
use file-watch.

Top Shelf event→state map (8 hooks, richer than our feed): SessionStart→Idle,
UserPromptSubmit/PreToolUse→Working, PostToolUse→Auto(→Working),
PostToolUseFailure→ToolFail, Notification→Waiting(if msg has "permission" else
Idle), Stop→Idle, SessionEnd→Ended. Payload: {state, agent, event, session_id,
cwd, title, terminal, pid}.

**Original insight still holds:** mostly already built. The hook→file→folder-watch
pattern (used by OTHER monitors like so-agentbar) is what
`.claude/hooks/golem-notify.sh` → `.worktrees/.status/feed.jsonl` already does
(`{ts, golem, event: gate|idle, message}`). It's a **transport + aggregator**
problem, not state detection.

Three existing state channels:

- gate/idle → `golem-notify.sh` → `feed.jsonl` (host-visible for WORKTREE
  golems; NOT for container golems).
- starting/working/error + last_activity → `agent-entrypoint.sh` `write_status()`
  → `<AGENT_ID>.json`, written to `/workspace/.worktrees/.status` INSIDE the
  container.
- container health/logs/labels → docker daemon (socket bind-mounted in every
  topology — the zero-touch discovery channel).

**The gap:** `crates/stibbons/src/agent/commands.rs:164-197` mounts the docker
socket + `{base_dir}/{repo}` but NOT `.worktrees/.status`, so container golem
state is trapped inside the container.

**Proposed:** new stibbons capability, host-installed (fan-in owner) +
container-available (emit side). Transport B (docker-socket read, zero-touch)
ships first; Transport A (bind-mount `.worktrees/.status` to host) is the richer
follow-up. Host sink must be **pluggable** (file-watch / statusline /
transcript-tail / socket-webhook) to support many monitor apps.

**LIVE-TESTED from a golem container → host bridge (2026-07-16), all PROVEN:**

- Container→host WORKS. `curl host.docker.internal:7823/health` →
  `{"ok":true,"sessions":N,"port":7823}`, 3ms. No bind-address blocker; remote
  POSTs accepted. (Was blocker #3 — resolved.)
- **`session_id` is the SOLE primary key.** POST with same session_id + new
  state updates in place (count stays). SessionEnd/`{"state":"Ended"}` drops the
  session (count →0). Clean register/update/deregister lifecycle.
- **`pid` is NOT part of the key** — two sessions sharing pid:88000 BOTH
  registered. `pid:null` accepted. Minimal payload
  `{state,agent,session_id}` (no pid/cwd/terminal/title) accepted. So pid +
  terminal are pure DISPLAY metadata → omit/null/collide freely for containers.
  User's feared pid-conflict is a non-issue; no need to fake unique pids.
- **Identity solution (flat list, works TODAY):** stamp
  `session_id="<project>-golem-<N>"` + `title="<project> · golem-N · <prompt>"`.
  Free-form key → stable, collision-free, human-readable per golem without
  needing Top Shelf nesting support.

**Remaining (nice-to-have, need HOST session — NOT blocking basic integration):**

1. Can Top Shelf UI GROUP/NEST by cwd/custom field (true hierarchy vs flat
   list)? If not, decide: forward per-golem to Top Shelf, or run own aggregator
   showing one Top Shelf icon. User is fine with flat-for-now; may build own
   sister project long-term.
2. Confirm `PostToolUseFailure` — may not be a real CC event (could be
   new/planned, or emulatable from containers). If it never fires, "errored"
   state just doesn't show — acceptable; goal is integrate-with-what-exists.
3. Subagent depth: net-new emission; adopting Top Shelf's 8-hook set advances it.

**DECISION (user):** ship as a NEW FEATURE gated by a new build arg
`POST_CLAUDE_EVENTS_TO_HOST` (default false). Depends on dev-tools (which installs
claude). Wire the Top Shelf hook + `NOTCHBAR_AGENTS_HOST=host.docker.internal`
into `~/.claude/settings.json`; the merge point is
`lib/features/claude-code-setup.sh:253-262`.

**SHIPPED (branch feature/claude-host-events, PR pending):** container feature
done — `lib/features/templates/claude/hooks/claude-host-event.sh` (topology-aware:
127.0.0.1 for worktree golems on host, host.docker.internal in containers;
identity `<project>-golem-N`; omits pid/terminal). Runtime settings.json hooks
merge added to `claude-setup` (gated, idempotent, preserves existing). Registry
feature `post_claude_events_to_host` (requires dev_tools). 8-event map. Also
cleaned 4 pre-existing shellcheck dead-code warnings in claude-setup; repo now 0
warning-level findings across 478 scripts. See [[shellcheck-policy-and-bash-deprecation]].

**FOLLOW-UP ISSUES FILED (2026-07-16):**

- **containers#738** — extend forwarder to worktree golems (host-side wiring;
  user wants to pick this up IMMEDIATELY after the current PR merges).
- **librarian#343** (epic) — golem event bus: multi-sink emission + orchestrator
  PUSH (flip the ~10min sweep). Reuses existing feed.jsonl + golem-watch --stream
  - harness Monitor; container HTTP forwarder becomes one sink. Repo boundary:
  librarian owns the bus/emitter/orchestrator-consumption (both golem types),
  containers owns transport + build-wired sinks.
- #735 comment cross-links all three.

Note: `.claude/memory/` is committed + mounted on host too, so a host session
inherits this note. See [[use-file-issue-skill]] — #735 was filed with raw `gh`
(should have used `/file-issue`).
