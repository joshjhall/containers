---
name: stale-git-index-lock
description: stale .git/index.lock is a virtiofs rename defect (#1086/#1114, closed not-planned), NOT lefthook or bindfs; retry after 2s, verify no holder, rm; no wrapper
metadata:
  type: feedback
---

In this workspace `.git/index.lock` is repeatedly left behind (~145-153KB, no
holder in `/proc/*/fd`). Measured 2026-10-13 (#1114): it is the mount, not
lefthook. Plain back-to-back `git add` + `git commit` with **no hooks** fails 2/10
on `/workspace`; the same stress in a `/tmp` clone fails 0/5 with either the
parallel or the sequential lefthook config. After git renames `index.lock` over
`index` the lock stays visible ~1.0-1.5s, and occasionally it is orphaned for
good. An earlier claim that lefthook `parallel: true` + `stage_fixed` caused it
was wrong — don't repeat it. Hooks only make it more frequent (extra index
writes right before the commit's own).

Bindfs is NOT the cause either: with the overlay peeled off (private mount
namespace, `unshare -m` + `umount -l`) raw virtiofs still failed (1/300 vs /tmp
0/300). #1114 closed not-planned 2026-10-13 as a Docker Desktop virtiofs
limitation. The doubled bindfs layer it surfaced was fixed separately (#1253).
The user explicitly declined a git retry wrapper ("more moving parts") and
moving `.git` off the mount; don't re-propose either. "Disable bindfs when UIDs
match" does nothing on macOS: virtiofs reports repo files as 0:0, so UIDs never
match there.

**Why:** waiting forever is wrong when the lock is orphaned; deleting a live lock
is wrong too; blaming the hook config sends the fix to the wrong layer.

**How to apply:** on "Unable to create .git/index.lock", sleep ~2s and retry
first (most are the transient ghost). If it persists: check mtime and that no
process holds it (`find /proc/[0-9]*/fd -lname '*/.git/index.lock'`), then
`rm -f` and retry once. Never `while [ -e lock ]` without a timeout. To test
hook/git behavior, use a clone in `/tmp` as the control. Back up uncommitted work
to /tmp before multi-step git sequences. Related:
[[case-insensitive-mount-shared-inode]], [[results-dir-fuse-incoherent]],
[[fuse-scratch-breaks-write-then-read]].
