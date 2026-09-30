---
name: unconsumed-default-status-fails-silently
description: An item registered but unhandled lands in a default status nothing consumes; every pipeline stage with a registry needs a completeness check against the stage upstream of it
metadata:
  node_type: memory
  type: feedback
  originSessionId: 087efad5-7289-4cb9-a206-cfa5db6cbde0
  modified: 2026-09-30T14:36:17.469Z
---

cargo-binstall was registered in check-versions (#532) but had no checker case. It
therefore got the default status `unchecked`, which neither auto-patch nor
update-versions selects. It sat at 1.20.0 while 1.24.0 was out, for months. It was
also missing an updater case and a checksum-refresh entry: **three layers** absent,
and none of them made a sound. #781 (a missing updater case) was the same shape one
stage later.

**Why:** a registry-driven pipeline (check → update → checksum refresh) is only
as complete as each stage's registry. A default or fallback status that no
downstream stage reads is where things go to disappear. When a completeness test
was added to update-checksums (#992), it immediately found 3 more orphans in
`lib/checksums.json`: ktlint, detekt and kotlin-language-server, none of which
were ever refreshed and which would have dropped to Tier-4 TOFU on their next bump.
It also found a dead `mado` entry.

**How to apply:** treat any default status as a failure. It should cause a
non-zero exit, be named in the output, and make automation hold. Give each stage's
registry a test that checks it against the upstream registry. Guard the whole
thing by running the **real** script offline (with `curl` stubbed to fail) and
asserting the unhandled count is zero, and add a fixture registration proving the
gate trips through `main()`. The earlier instance of this pattern:
[/auto-patch-inline-checksums.md](/auto-patch-inline-checksums.md). Related:
[/rust-tools-use-cargo-binstall.md](/rust-tools-use-cargo-binstall.md),
[/skips-render-as-passes.md](/skips-render-as-passes.md).
