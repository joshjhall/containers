---
name: Octarine Windows compilation
description: Octarine Windows support was fixed in v0.3.0-beta.1 — stibbons CI now requires Windows to pass
type: project
originSessionId: 207870b6-6a6f-497a-b52b-2bc47db47b0d
---

Octarine v0.3.0-beta.1 added Windows compilation support (previously blocked by rustc E0283 errors in v0.2.0).

**Why:** stibbons needs Windows support because it runs on the host (not just in containers). igor and luggage are container-only so don't need Windows.

**How to apply:** Windows rust-test in CI is now a hard requirement (no `continue-on-error`). If octarine regresses on Windows, the CI will catch it.
