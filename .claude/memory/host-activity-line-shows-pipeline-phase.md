---
name: host-activity-line-shows-pipeline-phase
description: "Host monitor golem activity line sources from next-issue pipeline phase, not launch prompt (#751)"
metadata:
  node_type: memory
  type: project
  originSessionId: 53803367-c187-4514-b9c2-e2d1eb5ea551
  modified: 2026-07-20T03:51:31.799Z
---

`claude-host-event.sh` (INCLUDE_HOST_EVENTS forwarder) sets a golem's host
activity line from the pipeline `phase` in
`<worktree>/.claude/memory/tmp/next-issue-{N}.json`, mapped to a verb:
select→Selecting, plan→Planning, implement→Building, ship→Shipping. Read on
every hook event (live readout). A `golem-N` id maps strictly by issue number;
the sole-state-file glob fallback is gated to AGENT_ID container golems only
(`m is None`) so a numbered golem never borrows an unrelated issue's phase.
Primary/human sessions + all error paths fall back to the prompt-derived title.
Worktree-root (`git rev-parse --show-toplevel`) is resolved in the shell block
so the embedded python stays git-free/pure-stdlib.

Stretch (not done): richer sub-progress like `Reviewing 2/7` needs the review
harness cycle/dimension counts persisted to the state file — a librarian-side
change to ship-issue/next-issue, tracked separately. Builds on [[host-monitor-state-forwarding-735]].
