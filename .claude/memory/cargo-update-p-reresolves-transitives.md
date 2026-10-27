---
name: cargo-update-p-reresolves-transitives
description: "`cargo update -p <crate>` also re-resolves that crate's transitive edges, so a 'pin-only' bump can churn unrelated lock lines"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 3ad4bd68-aaed-46e3-be65-6b6578d09680
  modified: 2026-10-27T14:44:54.739Z
---

`cargo update -p containers-common` (containers-db #483 / PR #491) bumped the
git pin **and** moved `serde-saphyr`'s `base64` edge from 0.23.1 to 0.22.1.
Both versions satisfy `>=0.21, <0.24` and both stayed in the lockfile, so
everything built. But the claim "only containers-common changed" was false.
`git diff --stat Cargo.lock` showed `2 +-`, which read as one package. It was
two separate one-line hunks. The pre-PR review caught it.

**Why:** a bump scoped to one dependency, when another issue owns the general
dependency update (#490 there), must not carry unrelated resolution changes.
The stat line hides how many hunks changed.

**How to apply:** after `cargo update -p`, read the actual `Cargo.lock` hunks
(`git diff Cargo.lock | grep '^[-+][^-+]'`), not `--stat`. For a true pin-only
bump, start from main's lockfile, edit only the `source = "git+...rev=..."`
line, and confirm cargo accepts it unchanged under `--locked`
(clippy/build/test). Related: [[assertions-must-discriminate]].
