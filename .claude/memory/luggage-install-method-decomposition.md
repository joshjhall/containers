---
name: luggage-install-method-decomposition
description: v5 luggage feature-port unblock — kind discriminant chosen over name dispatch; issue chain #805-813, order go→node→python
metadata:
  type: project
---

The luggage install engine shipped with only `script-installer` implemented and
one feature ported (rust, #407), blocking all 36 remaining bash feature scripts.
Decomposed 2026-08-22 into #805–#813.

**Decision: dispatch on a `kind` discriminant, not the catalog's free-string
`name`.** What shipped in #407 matched literal names (`"rustup-init"`), diverging
from #405's design. Adding go/node forced the choice; user chose `kind` (schema
change in containers-db + `InstallMethodKind` enum) so new catalog entries don't
each require a luggage code change.

**Why:** name-dispatch grows one match arm per tool forever and makes the catalog
non-authoritative — the opposite of luggage's purpose.

**How to apply:** foundations first (#805 kind, #806 de-rust-ify shared
engine, #807 streaming + manifest verify), then the methods themselves
(#808 binary-tarball, #809 source-build, #810 tier-4 TOFU), then ports in
order **go #811 → node #812 → python #813**. Node is the deliberate reuse check on #808 — if it forces
`tarball.rs` changes, the method didn't generalise, and that's worth recording on
the issue. Python is last: source-build + TOFU + ~15 configure flags.

Three rust-shaped hardcodes were the hidden blockers, all silently wrong rather
than loudly broken for other tools: `primary_binary()` (`"rust" => "rustc"`),
the `RUST_BINARIES` symlink const, and hardcoded `CARGO_HOME`/`RUSTUP_HOME`
cache layout. See [[luggage-vendored-catalog]] — production reads the vendored
`crates/luggage/testdata/catalog` (2 tools), not the sibling repo (7), so every
catalog addition must land in both. Schema changes go to containers-db FIRST per
[[evidence-run-validates-live-against-db-main]]. Adding an `InstallReport` field
breaks record-evidence — see [[luggage-installreport-field-workspace-test]].
