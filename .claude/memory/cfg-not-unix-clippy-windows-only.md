---
name: cfg-not-unix-clippy-windows-only
description: "#[cfg(not(unix))] stubs are only linted by windows-latest CI — local clippy on Linux can't see them; a no-op Ok(()) stub trips unnecessary_wraps"
type: feedback
metadata:
  node_type: memory
  type: feedback
  originSessionId: cbae40ad-761e-4e29-955d-bafd8381433f
  modified: 2026-10-28T19:30:25.878Z
---

Code behind `#[cfg(not(unix))]` (or any non-Linux cfg) is compiled out of every
local build here, so `cargo clippy --workspace --all-targets -D warnings` passes
locally while the `Rust Tests (stibbons) — windows-latest` job fails at its
clippy step, before any test runs. No Windows target is installed in the dev
container, so this cannot be reproduced locally.

Observed on PR #1539: a non-unix `set_executable(_path) -> Result<(), _>` stub
that just returns `Ok(())` tripped pedantic `clippy::unnecessary_wraps`. The fix
was `#[expect(clippy::unnecessary_wraps, reason = "must match the fallible unix
signature")]` on the stub. `#[expect]` is safe here because the item does not
exist on unix, so it cannot misfire as unfulfilled locally.

**Why:** a red Windows job reads like a test failure but is a lint on code
nobody compiled locally; the tests behind it have not actually run yet.

**How to apply:** when adding a `cfg(not(unix))`/`cfg(windows)` twin, write it
lint-clean for pedantic+nursery up front (expect `unnecessary_wraps` on no-op
fallible stubs, prefix unused params with `_`). After a Windows fix, confirm
the next run's log shows real `test result:` counts, not just a green tick.
Related: [[worktree-test-windows-path-separators]], [[zero-checks-is-not-green]].
