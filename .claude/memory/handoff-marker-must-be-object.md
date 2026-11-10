---
name: handoff-marker-must-be-object
description: "a golem that writes checkpoint.handoff_marker as `true` instead of the protocol object makes golem-handoff-relaunch.sh report not-due forever"
type: feedback
metadata:
  node_type: memory
  type: feedback
  originSessionId: e7bd7eee-fc72-4e33-b396-1c9178ece7dc
  modified: 2026-11-09T23:32:07.092Z
---

`golem-handoff-relaunch.sh check N` reports `state=not-due` /
`reason=... no checkpoint.handoff_marker` unless the marker is an object:
`{context_tokens, threshold, floor, pct_of_threshold, at, r_measured: null}`.
That is the shape `next-issue/handoff-protocol.md` specifies. golem-1524
(2026-11-09, 179% of threshold) wrote `"handoff_marker": true`. The check
then treated it as possibly parked at a human gate and refused to relaunch.
The golem had handed off and would have stayed idle indefinitely.

**Why:** the relaunch script uses the marker object to tell a real handoff
apart from a large golem waiting on a human gate. A boolean fails that test,
and the script deliberately fails closed rather than `/clear` an unanswered gate.

**How to apply:** when `check` says `not-due` for an idle golem whose budget
verdict is `handoff`, inspect `.checkpoint.handoff_marker` in
`.worktrees/issue-N/.claude/memory/tmp/next-issue-N.json`. If it isn't an
object, have the golem rewrite it from its own `context-budget.sh check .`
output, rather than editing the golem's state file yourself. Then re-run
`check` and expect `due`. Relaunch next, which may then hit
[[handoff-relaunch-refuses-dim-suggestion]].
