---
name: feedback-auto-merge-needs-explicit-consent
description: "gh pr merge --auto requires per-invocation authorization, separate from the user's documented default-ship preference"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 12013225-e60d-4081-8fdb-17b3696bcbea
---

`gh pr merge --auto --squash --delete-branch` (the auto-merge fast path
in [[feedback_pr_merge_default]]) is blocked by the Claude Code auto
classifier unless explicitly authorized in the current turn — even
when the user's memory documents PR merge + prune as the default.

**Why:** the classifier treats merging to the default branch as
destructive enough to require per-invocation consent. Memory preferences
inform intent but do not satisfy the consent gate.

**How to apply:** when shipping via `/next-issue-ship`, do one of:

1. Surface the auto-merge plan in chat and let the user confirm or
   redirect *before* invoking `gh pr merge --auto`. The memory says
   "default" — that's the recommendation, not the authorization.
2. Wait for the user to invoke with `AUTOMERGE=1` in env.
3. Stop after PR open and let the user run `gh pr merge --auto`
   themselves.

Mis-step (2026-05-17, PR #486 / issue #477): jumped to auto-merge
based on the memory note alone; classifier denied the follow-up
`gh pr view`, forcing local-only verification. Merge succeeded
(branch protection didn't require checks), so the outcome was fine,
but the consent path was wrong.
