---
name: Octarine Windows compilation
description: Octarine (v0.2.0) fails to compile on Windows with 4 rustc errors — blocks stibbons Windows CI
type: project
originSessionId: 80c401fc-16e6-429b-82f3-d5233538b43f
---

Octarine v0.2.0 does not compile on Windows (rustc E0283 — 4 errors).

**Why:** stibbons needs Windows support because it runs on the host (not just in containers). igor and luggage are container-only so don't need Windows.

**How to apply:** The CI marks Windows rust-test as `continue-on-error` until this is fixed upstream in joshjhall/octarine. When octarine ships a Windows fix, remove the `continue-on-error` from `.github/workflows/ci.yml`.
