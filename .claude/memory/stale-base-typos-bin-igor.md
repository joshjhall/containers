---
name: stale-base-typos-bin-igor
description: "Worktree branched from stale main re-adds deleted bin/igor; typos pre-push hook fails on the binary — rebase, don't debug"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 87ad3c8b-b984-4093-b481-46498eed55ba
---

A `.worktrees/issue-N` branch cut before an upstream commit that **deleted a
committed binary** (`bin/igor`, removed by #690) will carry that binary in its
push range (`origin/main..HEAD`), and the `typos` pre-push hook chokes on the
binary's bytes — reading random byte sequences as misspelled words — a failure
with **zero relation to your diff**.

**Why:** the push validates every file in the range, not just changed source.
An outdated base silently reverts upstream deletions into your range.

**How to apply:** when a pre-push hook (typos/osv/compose-validate) fails on a
file you never touched, first check `git diff --name-only origin/main..HEAD` — if
it lists files outside your change, `git fetch origin main && git rebase
origin/main` and re-push. Don't add typos excludes or `--no-verify`. Related:
[[worktree-push-hooks-gitignore]], [[pre-push-skips-network-tests]],
[[preexisting-osv-vuln-blocks-push]].
