---
name: outage-corrupted-pr-rollup
description: "a PR stuck BLOCKED after an Actions incident with all required checks green — dispatch runs don't count; close+reopen the PR to re-fire pull_request"
type: project
metadata:
  node_type: memory
  type: project
  originSessionId: 255a4852-ff32-4a3f-a6d2-82752f9f68e6
  modified: 2026-11-09T18:50:23.372Z
---

**A GitHub Actions incident can corrupt a PR's `pull_request` check suite so the
PR stays `BLOCKED` even after every required check has passed on the head SHA.**
Seen on containers-db PR #546 (2026-11-09): the run concluded `failure` with no
failed job, its job list flipped between queries, and the PR rollup dropped
`ajv + Rust validate` entirely. GitHub verified every commit signature, so the
`required_signatures` rule was not the cause.

`gh workflow run validate.yml --ref <branch>` does put a passing check-run on the
SHA, but it **does not unblock the PR**: the rollup only counts the
`pull_request` suite. `gh run rerun` was also refused ("cannot be retried").

**Why:** a dispatched run looks like it fixed the PR, and the tempting next
step is `gh pr merge --admin`. That bypasses the merge invariant when GitHub's
own state is inconsistent.

**How to apply:**

- First check `githubstatus.com/api/v2/summary.json` for an Actions incident.
- Confirm signatures from GitHub's side with `pulls/N/commits` → `commit.verification.verified`.
  Local `git log %G?` is not GitHub's view.
- Then run `gh pr close N` and `gh pr reopen N`, with a comment explaining why.
  `reopened` re-fires `pull_request` on the same SHA, with no new commit, so the
  reviewed tree is unchanged. PR #546 went `CLEAN` on the next run.
- Never `--admin` merge.

Related: [[zero-checks-is-not-green]] (the "never fired" variant),
[[feedback-full-review-before-merge]].
