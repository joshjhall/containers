---
name: stale-symlink-attrs-virtiofs
description: "virtiofs can cache symlink attrs as nlink=0/size=0, making git report them permanently modified; relink with ln -sfn"
metadata:
  node_type: memory
  type: project
  originSessionId: 1d2ee9f2-91fb-4c3e-86fa-a0de57fbb891
  modified: 2026-09-02T17:03:50.442Z
---

Long-lived symlinks on a virtiofs bind mount can end up with cached attributes
of `nlink=0, size=0` — impossible for a live symlink. Git compares the index's
recorded blob size against `st_size`, so such a link shows as modified forever
even though `git hash-object` on its target matches the index exactly. Content
was never wrong; only the metadata.

**Why:** this is *not* a bindfs bug. Freshly created symlinks pass through
bindfs correctly, and bare virtiofs with no bindfs overlay
(`/workspace/containers-db`) behaves the same. Only specific long-lived inodes
go stale, and dropping caches doesn't clear it (`/proc/sys/vm/drop_caches` is
read-only in the container).

**How to apply:** detect with `stat -c '%h' <link>` — `0` is the signal, and it
is false-positive-free because a *broken* symlink still reports `nlink=1`.
Repair by rewriting in place with the same target:
`ln -sfn "$(readlink "$p")" "$p"`. The `-n` is load-bearing: without it,
relinking a symlink that points at a directory creates the new link *inside*
that directory. Enumerate candidates cheaply with
`git ls-files -s | awk -F'\t' '$1 ~ /^120000 / { print $2 }'`.

Automated at startup by `lib/runtime/42-workspace-fs-health.sh`.
Related: [[case-insensitive-mount-shared-inode]].

**Also appears in fresh worktrees — and the startup automation above does NOT
cover them.** `worktree-new.sh` can produce a worktree whose repo-root symlinks
(`AGENTS.md` → `CLAUDE.md`, `.codegraph` → `/cache/codegraph`) are already
stale, so they surface as *deletions* in `git diff`/`git diff --stat` before you
have touched anything. Seen on #830, again on #871 — expect it on **every**
golem run, not occasionally.

`42-workspace-fs-health.sh` scans `PROJECT_ROOT` plus its submodules; a linked
worktree is neither, and #828's proposed fix caps discovery at depth 1 of
`/workspace` while worktrees sit at depth 3. Filed as #882 — **FIXED** in
PR #884 (merged 2026-09-02): the script now also walks every linked worktree,
enumerated from `git worktree list --porcelain` and gated to the main worktree
(that list is repo-global, so enumerating from inside a worktree would re-list
the whole set including the caller). Worktrees created after boot are picked up
by the hourly cron leg. Follow-up hardening tracked in #886.

**How to apply:** on a container built before that fix, run `git diff --stat`
before staging in a new worktree and treat symlink deletions you did not make as
this bug, not as your change — `git checkout -- <paths>` restores them, or
`workspace-fs-health` repairs them. Left unnoticed they ride along into the
commit as spurious symlink removals.
