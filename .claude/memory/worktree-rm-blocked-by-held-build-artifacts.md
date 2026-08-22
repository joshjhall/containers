---
name: worktree-rm-blocked-by-held-build-artifacts
description: "worktree-rm.sh can report \"uncommitted changes\" for an already-deregistered worktree; leftover cargo .o files resist rm with EBADF"
metadata:
  node_type: memory
  type: project
  originSessionId: 70fff190-ee3f-408b-b8e8-d31247eeaa88
  modified: 2026-08-22T04:17:38.140Z
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
2. `rm -rf` then fails on `target/debug/incremental/**/*.o` with
   **Bad file descriptor** (EBADF), leaving an artifacts-only shell (~200M).
   The cause is usually a **`rust-analyzer` still cwd'd into the worktree**
   (the LSP spawned while working there; it outlives the worktree). Find it by
   scanning `readlink /proc/*/cwd` for the worktree path — `lsof`-style fd
   scans miss it, since the hold is the cwd, not an open fd. Killing those PIDs
   releases the `.fuse_hidden*` files and `rm -rf` then reclaims the space.

   What can survive even that: zero-byte directory entries whose `unlink`,
   `stat`, and `ls` all return EBADF through the bindfs layer. They cost no
   disk. Because bindfs is mounted onto its own path
   (`/workspace/containers on /workspace/containers type fuse`), there is no
   underlying virtiofs path to delete them from inside the container — they
   clear on container restart. Same FS class as
   [[stale-symlink-attrs-virtiofs]].

Also note `gh pr merge --squash --delete-branch` aborts partway in a golem
worktree: the merge succeeds server-side but the local branch-switch dies on
`'main' is already used by worktree at /workspace/containers`, so the **remote
branch is never pruned**. Confirm with `gh pr view <N> --json state` and delete
the ref explicitly (`gh api -X DELETE repos/<owner>/<repo>/git/refs/heads/<branch>`)
rather than assuming the flag ran. Related: [[git-env-leak-breaks-worktree-tests]].
