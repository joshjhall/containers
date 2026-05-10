---
name: PR merge + branch prune is the default ship outcome
description: When a /next-issue-ship PR reaches green CI, merge it (squash) and prune the branch — don't stop at "PR open"
type: feedback
originSessionId: 3d724f14-9967-4620-bd7d-cf0435383b5c
---

When shipping via `/next-issue-ship` Option 1 (Branch + PR), don't stop at PR
creation + labeling. The intended end state is: PR merged to main, local +
remote feature branch deleted.

**Why:** Stated explicitly while shipping #424/PR #437. The user doesn't want
PRs sitting open waiting for a second prompt — once CI is green, merging is
the assumed next step.

**How to apply:**

- After the CI-wait loop returns "all green", proceed to
  `gh pr merge <num> --squash --delete-branch` (squash matches the auto-merge
  fast path's choice and the single-issue PR shape)
- After merge: `git checkout main && git pull --ff-only && git branch -D <feature>`
- If CI is red and unfixable, stop and report — don't merge
- Equivalent to running with `AUTOMERGE=1` after CI confirms, except merging
  is done explicitly rather than queued
- Skip the "PR open" celebratory stop; only stop after the branch is gone
