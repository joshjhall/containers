---
name: feedback-full-review-before-merge
description: "Never merge on a cap-stop over a narrow cycle; run a full-scope review pass on the final tree first, even past REVIEW_MAX_CYCLES"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 66e41fd1-0b53-402c-a820-bd6497155246
  modified: 2026-10-17T20:22:37.515Z
---

Before merging, the last clean review cycle must be a **full-scope** pass over
the exact tree being merged. A `C1-cap` stop with `capped_over=C3-narrow-zero`
(clean, but only the fix delta was reviewed) is not enough. Run another full
cycle even if that goes past `REVIEW_MAX_CYCLES`.

**Why:** On #1264 (PR #1300) the loop capped at cycle 5 on a clean narrow pass.
The operator asked for a 6th, full cycle. It found a real false positive
introduced by the cycle-4 fix (a `#.*` continuation arm matching a quoted `|
#`). That fix was reverted and cycle 7 (full) came back clean.

**How to apply:** When convergence returns `rule=C1-cap` and `capped_over` is
`C3-narrow-zero` or `C8-novel`, do not auto-merge. Run one more full-diff cycle,
with no delta args and `maxCycles` raised to match. If a fix keeps generating
new blocking findings on a heuristic (for example the regex scanner in
[[grep-q-pipefail-sigpipe-needs-load]]), prefer reverting the latest arm and
deferring to a follow-up over adding more regex. Related:
[[degraded-review-gate-is-not-a-pass]],
[[empty-review-dimension-is-not-a-pass]].
