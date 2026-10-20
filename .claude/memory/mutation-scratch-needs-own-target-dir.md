---
name: mutation-scratch-needs-own-target-dir
description: A mutation-check scratch copy sharing CARGO_TARGET_DIR with the real tree poisons it — cargo reuses the mutated build and real tests fail
metadata:
  node_type: memory
  type: feedback
  originSessionId: 526c53a2-1165-4312-acf4-bcf6c992043f
  modified: 2026-10-17T04:24:03.357Z
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

**How to apply:** use `CARGO_TARGET_DIR=/tmp/cargo-mut-<n>` for the mutated copy
and delete it afterwards. If a real run fails right after a mutation check,
suspect a shared target dir before suspecting the code. Extends
[[mutation-checks-on-scratch-copies]] and
[[fuse-scratch-breaks-write-then-read]].
