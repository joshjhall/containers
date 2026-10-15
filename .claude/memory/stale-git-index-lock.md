---
name: stale-git-index-lock
description: "index.lock contention is host↔container git index ping-pong (Zed, zed#52265), fixed by core.checkStat=minimal; virtiofs rename ghost is a minor second cause; verify no holder, rm; no wrapper"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 093c56c6-fee4-42ce-beed-2a6b86434986
  modified: 2026-10-15T03:26:14.519Z
---

The main cause of `Unable to create '.git/index.lock': File exists` (and
lefthook `couldn't stage fixed files … exit status 128`) is two git clients
fighting over one index, not the mount. Measured 2026-10-14 (#1114 updated):
with the repo open in Zed, git on the macOS host and Zed's remote server in the
container both refresh `.git/index`. Each sees the other's `dev`/`ino`/`uid`/`gid`
as changed and rewrites the whole index under the lock. `git ls-files --debug`
showed a container write (`dev:50 uid:1000`) rewritten to host values
(`dev:16777244 uid:501`) within about 10s. Zed runs `git --no-optional-locks diff
--numstat -- <file>` per changed file, and porcelain `git diff` ignores
`--no-optional-locks`: `refresh_index_quietly()` in `builtin/diff.c` has no
`use_optional_locks()` gate (only `git status` checks it). The fix,
`git config core.checkStat minimal` (set in this repo's `.git/config`, which both
sides share), took container `git add` failures from 6/300 to 0/300. Upstream:
zed-industries/zed#52265 (jackdouglas's diagnosis there). The fix for Zed is
plumbing `diff-files`/`diff-index --numstat` or `-c diff.autoRefreshIndex=false`;
both wrote the index 0 times in 5 tries.

Earlier conclusions that were wrong, and why: "virtiofs, NOT lefthook" came from
`/workspace` vs `/tmp` tests, which were really Zed-watched vs unwatched. A clone
on the same mount had 0/400 failures against 6/400 for the watched repo. A
passive watch "saw no host git" only because the repo was idle; the host reacts
to container writes. Lefthook fixers fail most often because they rewrite
several files and then re-stage, so Zed fires one diff per file right before
lefthook needs the lock. Also ruled out: the git 2.56 base-image upgrade (same
rate as 2.47), loose objects or gc, and codegraph (read-only git).

There is still a minor second cause: virtiofs occasionally leaves a 0-byte
`index.lock` after git's rename (#1086, 6-10 per 10k cycles on raw virtiofs,
also visible under bindfs). The user declined a git retry wrapper and moving
`.git` off the mount; don't re-propose either.

**Why:** blaming the mount sent the fix to the wrong layer for weeks, while a
one-line repo config removes the main cause.

**How to apply:** if lock errors come back, check `git config core.checkStat`
first (a fresh clone won't have it), and check whether the user is in Zed. For a
stuck lock: sleep ~2s and retry. If it persists, confirm no holder
(`find /proc/[0-9]*/fd -lname '*/.git/index.lock'`) and its mtime, then `rm -f`
and retry once. Never `while [ -e lock ]` without a timeout. Fallback when a
`stage_fixed` commit keeps failing: `git diff --cached` to a patch, `git clone
--no-local` into `/tmp`, apply, and commit + push there (hooks still run; never
`--no-verify`). When diagnosing contention, sample `/proc/*/fd` for the holder
right after a `touch` instead of watching an idle repo. Related:
[[zed-every-boot-startup-replay]], [[case-insensitive-mount-shared-inode]],
[[results-dir-fuse-incoherent]], [[fuse-scratch-breaks-write-then-read]].
