---
name: etxtbsy-held-fd-linux-only
description: Inducing ETXTBSY by holding an open write fd across exec is Linux-only; macOS lets the exec succeed
metadata:
  node_type: memory
  type: project
  originSessionId: cba672a9-a40f-42e5-a7a5-a2e353f00dd5
---

Holding an open **writable** fd to an executable and then `exec`ing it forces
`ETXTBSY` (errno 26, "text file busy") **only on Linux**. macOS/Darwin lets the
`exec` succeed while the write fd is held (returns `ExitStatus(0)` with real
stdout), so any test using this technique to induce ETXTBSY deterministically
must be `#[cfg(target_os = "linux")]`, not `#[cfg(unix)]`.

**Why:** the luggage installer's `run_version_check` retries on ETXTBSY (see
[[luggage-tooldb-design]]); #589 added exhaustion/false-contract unit tests in
`crates/luggage/src/installer/idempotency.rs` that hold a write fd to force the
error. They passed locally + on ubuntu/Run-Tests but failed
`Rust Tests (stibbons) — macos-latest`.

**How to apply:** gate held-fd ETXTBSY unit tests to `target_os = "linux"`. The
production retry path stays covered on every unix by the parallel
write-then-exec regression tests in `crates/luggage/tests/install_rust.rs`
(those rely on the fork race and only assert success, so they're portable).
Note the `stibbons` macOS/Windows CI legs run the **whole workspace** (luggage
included), so a luggage-only change can still redden a stibbons-labeled check.
