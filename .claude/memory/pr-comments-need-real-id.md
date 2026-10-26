---
name: pr-comments-need-real-id
description: "ship-issue pr-cycle harness forces clean:false when a prComments entry has no `id`, even with zero findings"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 4b169ba1-136d-473b-b15c-e43b539107ff
  modified: 2026-10-26T03:55:09.093Z
---

Each `prComments` entry passed to the ship-issue `workflow.js` harness
(`phase: "pr-cycle"`) needs the comment's real platform `id` (e.g.
`gh api repos/O/R/issues/N/comments --jq '.[].id'`). If you pass one without an
`id`, the judge reports the comment as addressed under an index id like `"0"`.
`sameCommentId` (`String(a) === String(b)`) then can't match it, so the harness
logs `1 PR comment(s) not yet resolved-or-deferred` and returns `clean: false`
even when findings are 0. The convergence check can still say `stop`
(`C4-zero`) on that cycle. Do not merge on it: the merge invariant needs
`clean: true`.

**Why:** happened on containers-db PR #466 (#455). A comment that linked to my
own deferred follow-up was passed without an id, which cost a fourth
full-scope cycle.

**How to apply:** when you build `prComments`, always include `id` from the
API, including for your own informational comments. On `clean: false` with 0
findings, read the harness `logs` for the reason before you rerun anything.
Related: [[degraded-review-gate-is-not-a-pass]],
[[harness-placeholder-args-fake-review]].
