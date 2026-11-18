---
name: solo-review-result-not-on-disk
description: "A solo (non-golem) ship-issue review run writes no attempt<N>.json — the result only arrives in the Workflow task-notification, so review-convergence.sh has nothing to read"
type: feedback
metadata:
  node_type: memory
  type: feedback
  originSessionId: 9d8e13c5-2075-4923-85eb-ea7fbbfbccad
  modified: 2026-11-17T23:19:22.560Z
---

When `/workflow:ship-issue` runs **solo**, in the primary checkout rather than
a golem worktree, the review harness's cycle result is **never written to
disk**. `~/.cache/librarian-review/solo-<N>/` holds only `args1.json`,
`files.txt` and `.scratch-stamp`. There is no `attempt<N>.json` or
`pr-attempt<N>.json`. The `journal.jsonl` in the transcript dir holds
per-agent results only, not the judged summary. The full result (`clean`,
`blocking`, `deferrable`) exists only in the Workflow **task-notification**.

**Why:** on 2026-11-17 (#561, PR #630), `review-convergence.sh` and
`review-engagement.sh` had no result file to read. Re-creating one by
hand-transcribing the notification was blocked by the auto-mode classifier
as "Undermining Oversight", correctly: the agent would be authoring the input
to its own merge gate. The run stalled until the operator picked a path.

**How to apply:** in a solo run, don't try to synthesize `attempt<N>.json`.
Read each cycle's verdict straight from the task-notification, and treat the
convergence predicate as unavailable, using the documented fallback of
`cycle` vs `REVIEW_MAX_CYCLES`. The merge rule still holds: the last clean
cycle must be a **full** pass ([[feedback-full-review-before-merge]]), so
after a narrowed clean cycle, run one full `pr-cycle` and merge on clean +
green rather than parking. Related: [[post-pr-review-artifact-is-pr-attempt]]
covers where golem runs DO write the file.
