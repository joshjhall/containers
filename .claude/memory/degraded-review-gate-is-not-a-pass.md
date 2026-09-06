---
name: degraded-review-gate-is-not-a-pass
description: "A review dimension that dies on a 429 returns no verdict, not a clean one; re-run the missing dimension before merging"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 11d74818-fdfd-4893-b88b-57f13183da52
  modified: 2026-09-06T21:47:50.407Z
---

The ship-issue review harness fans six dimensions in parallel. On #924/PR #925
the `correctness` dimension died with an API 429 and never reported, and the
`security` dimension's safety classifier timed out. Five dimensions came back
clean and CI was fully green — so "green" was the tempting read.

The missing dimension was the one that found the most serious defect in the PR:
a loader-validation change that could brick a project
([[validation-on-load-is-a-breaking-change]]). Re-running just that dimension
cost ~5 minutes and changed what shipped.

**Why:** a harness failure and a clean verdict are indistinguishable in the
aggregate output — both leave a dimension with no findings. The judge grades
what it received and cannot tell absence-of-findings from absence-of-reviewer.
This is the same shape as [[zero-checks-is-not-green]] and [[skips-render-as-passes]]:
the pipeline reports success for work that never ran.

**How to apply:** read the harness's `<failures>` block, not just the findings.
On a dimension that errored, re-run **that dimension** before merging — a
targeted `dev-core:code-reviewer` dispatch with an explicit single-dimension
contract is enough when the harness's judge has already graded the others, and
is far cheaper than re-fanning all six. Say plainly that the gate was degraded
rather than calling the PR reviewed. The merge invariant needs CI green **and**
a review that actually terminated; a dimension that never ran fails the second
half.
