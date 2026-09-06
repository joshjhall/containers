---
name: virtiofs-ebadf-not-bindfs
description: Wedged worktree files (EBADF on stat/unlink) come from virtiofs, not bindfs; unmounting the overlay does not help
metadata:
  type: project
---

`.worktrees/issue-N` remnants whose entries return `Bad file descriptor` (EBADF)
from `stat`/`unlink`/`rename` while still appearing in `readdir` are a
**virtiofs** failure, NOT a bindfs one — contradicting the comment in
`worktree-rm.sh` `remove_leftover_dir` ("on the documented macOS/VirtioFS
bindfs overlay").

**Measured** (2026-09-06, issue-849/issue-850 remnants):

- `sudo unshare -m --propagation private` + `umount -l /workspace/containers`
  exposes the lower virtiofs. The wedged entries fail *identically* there.
- A completely fresh `mount -t virtiofs host /mnt/fresh` in that namespace
  also returns EBADF — so it is not a container-side dentry cache.
  `drop_caches` is unavailable (`/proc/sys` is read-only) and irrelevant.
- The host (macOS) virtiofsd has lost the inode mapping for those names; the
  directory entry survives on the host FS but no fd can be opened for it.

**What still works** (this is the exploitable part):

- The *containing directory* renames fine, and new files can be created and
  deleted inside it. Only the pre-existing entries are wedged.
- So a wedged tree can always be **quarantined by rename** (`mv issue-849
  .trash-849`), freeing the `issue-N` path for reuse immediately.
- Wedged entries hold **zero live bytes** (`find -type f -printf %s` sums to 0).
  The multi-GB figure is host-side space that only a host-side unlink or a
  Docker Desktop VM restart reclaims — no in-container call can.

**Prevention**: `/cache` is on the container overlay, not virtiofs. Keeping
Rust/C/C++ build artifacts off the virtiofs mount (e.g. `CARGO_TARGET_DIR`
under `/cache`) avoids creating the churn that triggers this — every observed
wedge was `target/debug/incremental/*.o`.

Related: [[stale-symlink-attrs-virtiofs]], [[case-insensitive-mount-shared-inode]],
[[fuse-scratch-breaks-write-then-read]]
