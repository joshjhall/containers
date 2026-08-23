---
name: results-dir-fuse-incoherent
description: "tests/results/ is on the workspace FUSE mount, which loses read-after-write under concurrency — the real cause of the #821 flake class"
metadata:
  node_type: memory
  type: project
  originSessionId: c60bf2a2-5cac-4ab2-a8cb-8566c87246e8
  modified: 2026-08-23T18:44:04.989Z
---

`$RESULTS_DIR` (`tests/results/`) lives in the workspace, which is a **FUSE
mount** (bindfs/VirtioFS) in these containers. Under concurrent load a
just-appended block is **not reliably visible to an immediately following
read**. `/tmp` is native overlay and is unaffected.

This is the root cause of the long-standing "intermittent single-suite failure,
cause unknown" flake class (**#821**) — found while fixing #818 (PR #824,
merged 2026-08-23).

**The signature is distinctive and worth memorizing:** the code under test
writes successfully, *reports* success, and exits 0 — yet the next read does not
see the data. In #818 the script logged `Added 6 entries` and returned 0 while
the following `grep` found nothing. If writes succeed and then aren't readable,
suspect the mount, not the test's ordering.

Measured, with a bare write-then-read loop and **no test framework involved**
(8 procs x 400 iterations): **6 lost / 3200 on the FUSE workspace, 0 / 3200 on
native overlay.**

**Fixing uniqueness does not fix this.** #817 fixed a real and *different* bug
(scratch-dir name collisions, see [[tests-share-results-dir]]). For #818, making
dir names unique per test case moved the concurrency reproducer only 3/100 ->
2/100; moving scratch to `mktemp -d` took it to **0/100**. That middle
measurement is what proved the mount was at fault — don't stop at the
uniqueness fix and assume it worked.

**Fix:** use `mktemp -d`, which honours `TMPDIR` (native overlay). This is what
`tests/framework.sh`'s own default `setup()` already does — the affected suites
are precisely the ~30 that *override* it to point `TEST_TEMP_DIR` at
`$RESULTS_DIR`. Keep run reports and the reaper on `$RESULTS_DIR`; relocate only
the per-test scratch trees.

Confirmed still-affected as of PR #824: `tests/unit/base/aliases.sh` (2/64 under
concurrency, identical signature). Latent pre-#817 fixed-`$$` pattern remains in
`tests/unit/runtime/workspace-fs-health.sh` and
`tests/unit/runtime/lib/resolve-container-user.sh` (neither reproduced, 0/30).

A corollary for diagnosis generally: a suite that passes standalone but fails in
a full/concurrent run is not automatically an ordering bug. Reproduce under
**concurrency** (N copies in parallel, several rounds) rather than by
re-running or shuffling — shuffling passed 5/5 here while the real bug was live.
Also beware instrumenting by copying a suite to `/tmp`: these suites `source`
`framework.sh` by relative path and silently fail to run there, which reads as
"no failures". Instrument in-tree.

Related: [[tests-share-results-dir]], [[stale-symlink-attrs-virtiofs]],
[[case-insensitive-mount-shared-inode]] — other artifacts of this mount.
