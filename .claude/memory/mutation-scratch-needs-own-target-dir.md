---
name: mutation-scratch-needs-own-target-dir
description: A mutation-check scratch copy sharing CARGO_TARGET_DIR with the real tree poisons it — cargo reuses the mutated build and real tests fail
metadata:
  node_type: memory
  type: feedback
  originSessionId: 526c53a2-1165-4312-acf4-bcf6c992043f
  modified: 2026-11-10T17:23:34.861Z
---

When running a mutation check on a scratch copy of a Cargo workspace, give the
scratch copy its **own** `CARGO_TARGET_DIR`, never the one the real tree uses.

**Why:** cargo fingerprints workspace members by package identity and mtimes,
not by source path. On containers-db #407, a scratch copy at `/tmp/mut-407`
(guard removed) shared `CARGO_TARGET_DIR=/tmp/cargo-407` with the real worktree.
The next real `cargo test --release --workspace` reused the mutated artifact,
and the new guard test "failed" against source that was correct. Only `rm -rf`
of the target dir fixed it. That cost a misdiagnosis round, and it could easily
have been mistaken for a real regression.

There is a second symptom, which fires even when the scratch copy is NOT mutated.
`env!("CARGO_MANIFEST_DIR")` is compiled into test binaries. A scratch run (for
example an overlay of a PR's data) that builds into the real `target/` bakes the
scratch path into the binary. Once the scratch dir is deleted, real runs fail on
a missing path: `read tools/: NotFound`, with every test in the binary failing
(6/6). Hit on containers-db 2026-11-10 while validating #570's data overlay. It
looked like a bad merge until `strings <bin> | grep /tmp/tmp.` showed the stale
path.

**How to apply:** use `CARGO_TARGET_DIR=/tmp/cargo-mut-<n>` for any scratch copy,
mutated or not, and delete it afterwards. If a real run fails right after a
scratch check, suspect a shared target dir before suspecting the code. A
missing-path panic (`NotFound`) on files you can `ls` points at a baked-in
`CARGO_MANIFEST_DIR`. Confirm with `strings` on the test binary, then
`touch` a test source file to force a rebuild. Extends
[[mutation-checks-on-scratch-copies]] and
[[fuse-scratch-breaks-write-then-read]].
