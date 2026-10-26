---
name: post-pr-review-artifact-is-pr-attempt
description: "Post-PR review results are written to pr-attempt<N>.json, not attempt<N>.json — glob both before holding a golem merge for \"no post-PR review\""
metadata:
  node_type: memory
  type: feedback
  originSessionId: 4b169ba1-136d-473b-b15c-e43b539107ff
  modified: 2026-10-25T23:07:24.885Z
---

When verifying a golem's merge gate from the orchestrator, the ship-issue
harness writes **pre-PR** cycles as `attempt<N>.json` but **post-PR** cycles as
`pr-attempt<N>.json` (both under
`~/.cache/librarian-review/golem-<N>/`, each with `"phase": "pre-pr"` or
`"pr-cycle"`). Globbing only `attempt*.json` makes a clean post-PR review
invisible.

**Why:** on 2026-10-25 the orchestrator held PR #1469's merge for "no post-PR
review found" when `pr-attempt1.json` (pr-cycle 1, clean, all dimensions
engaged, covering the exact head) already existed — a wasted round-trip. The
hold on PR #1462 the same day was legitimate (no pr-cycle file at all).

**How to apply:** check `ls -t ~/.cache/librarian-review/golem-N/*attempt*.json`
and read the newest file's `phase`/`cycle`/`blocking`/`unengaged_dimensions`;
confirm its mtime is after the PR head commit. Only hold the merge if no
`pr-cycle` artifact covers the head. Related: [[feedback-full-review-before-merge]],
[[empty-review-dimension-is-not-a-pass]].
