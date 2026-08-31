---
name: worktree-rm-blocked-by-held-build-artifacts
description: "worktree-rm.sh can report \"uncommitted changes\" for an already-deregistered worktree; leftover cargo artifacts resist rm because a rust-analyzer holds them open — find it with lsof +D, do not wait for a restart"
metadata:
  node_type: memory
  type: project
  originSessionId: 70fff190-ee3f-408b-b8e8-d31247eeaa88
  modified: 2026-08-31T19:00:16.930Z
---

Post-merge teardown of a golem worktree can leave `.worktrees/issue-N/` behind
even after the branch and git registration are gone (observed 2026-08-21,
PR #795).

Two distinct symptoms, both cosmetic once diagnosed:

1. `worktree-rm.sh N` prints "has uncommitted changes" when the worktree is
   *already* deregistered — `git worktree list` doesn't show it and
   `.git/worktrees/<name>` is absent, so the script's status probe fails
   (`fatal: not a git repository: (null)`) and is read as dirty. Verify with
   `git worktree list` + `ls .git/worktrees/` before believing the dirty
   report; diff the worktree's changed files against merged `origin/main` to
   confirm nothing unmerged is stranded, then remove the directory directly.
2. `rm -rf` then fails on `target/debug/**` — either **Bad file descriptor**
   (EBADF) or `Directory not empty` on a dir holding only `.fuse_hidden*`
   entries — leaving an artifacts-only shell (~200M).

   **This is a held-open file, not a filesystem state, and not something to
   wait out.** `.fuse_hidden*` is FUSE's marker for a file that has been
   unlinked while some process still holds it open; it disappears the moment
   the holder does. Diagnose in three steps (observed 2026-08-31, PR #878):

   ```bash
   lsof +D .worktrees/issue-N/target/debug/deps   # names PID + the DEL REG fds
   ls -l /proc/<pid>/cwd                          # confirm it is rooted in the worktree
   kill <pid> <parent-pid>                        # then rm -rf succeeds first try
   ```

   The holder is usually a **`rust-analyzer` pair** — the LSP plus its
   `rust-analyzer-proc-macro-srv` child — spawned when the worktree was opened
   in an editor, outliving the worktree. Before killing, confirm it is an
   orphan: `lsof -p <pid> | grep -c /workspace/<repo>/crates` returning 0 means
   it holds nothing in the main checkout and is serving only a directory git
   has already forgotten.

   **`lsof +D` works — do not skip it.** An earlier version of this note said
   fd scans miss the hold because it is "the cwd, not an open fd." That is
   wrong: on PR #878 `lsof +D` listed all 23 fds as `DEL REG` against the one
   PID directly. The `/proc/*/cwd` scan is a useful *confirmation* that the
   process belongs to the worktree, not the primary way to find it.

   Filed as a suggested improvement on #864: teardown should name the holding
   PIDs instead of leaving the operator to find them. Related: [[stale-symlink-attrs-virtiofs]].

Also note `gh pr merge --squash --delete-branch` aborts partway in a golem
worktree: the merge succeeds server-side but the local branch-switch dies on
`'main' is already used by worktree at /workspace/containers`, so the **remote
branch is never pruned**. Confirm with `gh pr view <N> --json state` and delete
the ref explicitly (`gh api -X DELETE repos/<owner>/<repo>/git/refs/heads/<branch>`)
rather than assuming the flag ran. Related: [[git-env-leak-breaks-worktree-tests]].

**Squash-merge adds a third symptom** (observed 2026-08-27, PR #859). After a
squash merge, `git branch -d feature/issue-N` refuses with "not fully merged":
the branch tip is not an ancestor of the squash commit, by construction. That
warning carries no information after a squash — confirm the content actually
landed with `git diff --stat feature/issue-N origin/main -- <changed-paths>`
(empty = identical), then use `-D`. Also note `gh pr merge --delete-branch`
aborts the *remote* prune when the local delete fails, so the remote branch
survives; delete it with `git push origin --delete` (add `--no-verify` — the
pre-push hooks run on a deletion, where they are meaningless, and can block it).

**When removal persists with no holder:** only after `lsof +D` **and** the
`/proc/*/cwd` scan both come back empty is this genuinely unreclaimable. Check
`du -sh` — a 0-byte residue is empty directory scaffolding over inodes FUSE has
already unlinked, costing no disk, and bindfs being mounted onto its own path
(`/workspace/containers on /workspace/containers type fuse`) leaves no
underlying virtiofs path to delete it from inside the container. That case does
clear on restart; don't keep retrying.

**Reach for restart last, not first.** Two attempts at `rm -rf` failing is not
evidence of the no-holder case — on PR #878 it looked identical to it, and the
actual cause was one killable process. Run `lsof +D` before concluding anything
survives until restart, and never report "clears on container restart" without
having done so: it implies an unbounded wait and ~200M pinned, when the real
remedy is three commands.
