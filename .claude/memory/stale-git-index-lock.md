---
name: stale-git-index-lock
description: .git/index.lock repeatedly left stale (~145KB, minutes old, no git process); verify no holder, then rm — never loop-wait on it
metadata:
  type: feedback
---

In this workspace `.git/index.lock` is repeatedly left behind (seen 6+ times on
2026-10-11/12): ~145KB, minutes old, no git process alive, nothing holding it
open. It is likely something in the IDE/tooling touching the index on the
virtiofs/bindfs mount, not a concurrent git operation. A `while [ -e
.git/index.lock ]; do sleep; done` guard therefore hangs until the Bash timeout
(twice burned 10 minutes) and a lefthook re-stage step fails with exit 128
mid-commit.

**Why:** waiting is wrong when the lock is orphaned; deleting a live lock is
wrong too.

**How to apply:** on "Unable to create .git/index.lock", check its mtime and
`ps` for git processes (and `lsof` on the file). If no holder → `rm -f` it and
retry once. Before any multi-step git sequence (stash/switch/rebase) back up
uncommitted work to /tmp first — a lock failure mid-`stash` can leave you
unsure what state the tree is in. Related: [[case-insensitive-mount-shared-inode]],
[[results-dir-fuse-incoherent]].
