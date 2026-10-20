---
name: merge-commit-breaks-conform-ci
description: A merge commit on a PR branch makes CI's `conform enforce` exit 1 with "failed to get commit message: EOF" — update a stale branch by rebase, never merge
metadata:
  type: project
---

Bringing `main` into a PR branch with a **merge commit** fails the Run Tests
job — not in any test, but in the conform commit-lint step:
`conform enforce --base-branch origin/main` hits the two-parent commit and dies
with `failed to get commit message: EOF`, exit 1. The job log shows no `FAIL`
line at all; the only signal is `##[error]Process completed with exit code 1`
right after that EOF line, so grepping for test failures finds nothing.

It is the same error text as the empty-range case guarded in #725, but a
different trigger, and that guard does not cover it. Found on PR #1278
(2026-10-15): merge commit `4ce6cdca` failed; the same content as a single
linear commit passed. The local commit-msg hook also rejects git's default
`Merge remote-tracking branch …` message, which is the first warning sign.

**Why:** conform only handles linear history; the repo is squash-merge and
linear anyway.

**How to apply:**

- Update a stale PR branch with `git rebase origin/main`. If replaying many
  commits would re-hit the same conflict repeatedly, `git reset --soft
  origin/main` and recommit as one commit; the PR squash-merges regardless.
  Push with `--force-with-lease=<branch>:<old-sha>`.
- To verify locally, run `conform enforce` in a throwaway **/tmp clone**, not
  in a `.worktrees/` linked worktree. In a worktree it fails with an unrelated
  `reference not found`, which can't distinguish good commits from bad.

Related: [[ci-lint-fails-on-deleted-paths]], [[rebase-before-blaming-your-change]],
[[worktree-push-hooks-gitignore]].
