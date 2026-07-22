---
name: review-harness-destructive-rm-746
description: "ship-issue pre-PR review subagent deleted the repo's real .worktrees via an unresolved ..-path rm while reproducing a bug against the LIVE checkout"
metadata:
  node_type: memory
  type: project
  originSessionId: 32c61858-f4e3-4160-9082-e6742c6d07bd
  modified: 2026-07-19T22:12:28.022Z
---

During #746's `/ship-issue` **adversarial pre-PR review** (workflow.js
`phase: pre-pr`), the `review:correctness` subagent
(`agent-ae367beab3a908176`) deleted `/workspace/containers/.worktrees` —
destroying the running `issue-746` and `issue-697` worktree *directories*
mid-session. The completed-review task notification carried a
`<failures>` SECURITY WARNING naming the exact command.

**Root cause (forensic, from the agent transcript):** the reviewer was
verifying the `git-common-dir` project-resolution logic I added. It correctly
found the `..` bug, but reproduced it **against the live repo** instead of a
`/tmp` sandbox (it *did* use /tmp for ~25 earlier steps, then switched to
in-place). The fatal command:

```bash
cd /workspace/containers/lib/features
common_dir="$(git rev-parse --git-common-dir)"   # -> ../../.git (RELATIVE from a subdir)
case "$common_dir" in /*) ;; *) common_dir="$(pwd)/$common_dir" ;; esac
root="$(dirname "$common_dir")"                  # -> /workspace/containers/lib/features/../..
mkdir -p "$root/.worktrees/.status"
rm -rf "/workspace/containers/lib/features/../../.worktrees"   # ← ../.. => /workspace/containers/.worktrees
```

The `rm -rf` (cleanup of the `.status` dir its own repro had `mkdir`'d)
resolved the unresolved `../..` to the REAL `.worktrees` and wiped it. The
agent then noticed (ran `git worktree list/repair`, tried `git checkout -- .`).

**Damage (all verified recovered):**

- issue-746: intact — committed before the delete, shipped/merged as PR #747.
- issue-697: **fully recovered.** git's per-worktree index lives at
  `.git/worktrees/issue-697/index` (OUTSIDE the deleted working dir), so its 3
  staged files survived; the owning session recreated the working dir at
  16:55 and working tree == index (no `git diff`). No lost work after all —
  the security warning's "destroyed uncommitted changes" was worst-case; the
  index-outside-worktree layout saved it.

**Two independent lessons:**

1. **Harness safety (the real bug):** a read-only correctness reviewer must
   NEVER run destructive commands against the live checkout. Reproductions
   belong in `/tmp` sandboxes only. An `rm -rf` containing an unresolved `..`
   is a landmine — canonicalize (`cd … && pwd`) before any destructive op.
   Candidate follow-up: sandbox/deny `rm -rf` outside a scratch dir in the
   ship-issue review agents. This is a librarian (workflow plugin) concern —
   the harness is `/opt/librarian/plugins/workflow/skills/ship-issue/workflow.js`.
2. **Recovery worked** because commits are durable and the git index is
   outside the working tree. When a worktree vanishes mid-run: `git worktree
   prune` + `git worktree add <path> <branch>` recreates it on the intact
   branch; the pre-PR review can be finished WITHOUT re-running the harness
   (recover partials via `recover-journal-partials.sh <transcriptDir>/journal.jsonl`).

See [[golem-supervised-auto-mode]], [[preexisting-osv-vuln-blocks-push]].
