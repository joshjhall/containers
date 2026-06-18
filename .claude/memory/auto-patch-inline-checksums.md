---
name: auto-patch-inline-checksums
description: "Auto-patch checksum gap — tools pinned inline in setup.sh need the inline updater, not just checksums.json"
metadata:
  node_type: memory
  type: project
  originSessionId: d6c19eb7-d430-4702-b7c6-80cf52f105a0
---

The weekly auto-patch bumps versions (`update-versions.sh`) then refreshes
checksums (`update-checksums.sh`). Most tools store their SHA256 in
`lib/checksums.json`, but a few pin it **inline** in `lib/base/setup.sh`
(`COSIGN_SHA256_*`, `ZOXIDE_SHA256_*`). If a tool's version is bumped but its
inline checksum isn't, the base image build fails `✗ Checksum verification
failed`, CI goes red on the `auto-patch/*` branch, auto-merge never fires, and
Pushover pages. This is what stalled v4.19.6 (cosign 3.0.6 → 3.1.1).

**Why:** `update-checksums.sh` originally only wrote to `checksums.json`. Inline
constants in `setup.sh` were tracked by `check-versions.sh` (so they got bumped)
but never re-checksummed.

**How to apply:** Any tool pinned inline in a script with a `*_SHA256_AMD64/ARM64`
constant must be added to `TOOL_CHECKSUM_REGISTRY_INLINE` in
`bin/update-checksums.sh` (fixed in PR #514). That registry's `update_inline_checksum`
compares-and-replaces (inline constants always have a value, so there's no
missing/placeholder state to key off). The `cosign` entry in `checksums.json` is
stale (3.0.5) and **unused** — base install reads the inline constant. Don't
hand-edit `auto-patch/*` branches; fix the tooling on main and re-trigger via
`workflow_dispatch`. See [[v5-architecture]].
