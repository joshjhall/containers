---
name: luggage-installreport-field-workspace-test
description: Adding a field to luggage InstallReport breaks record-evidence/stibbons; test --workspace not -p luggage
metadata:
  node_type: memory
  type: feedback
  originSessionId: d391ee17-3d6d-49e5-b73c-9bf2cbda689c
---

Adding a field to `luggage::InstallReport` (or any pub struct other crates
build with a struct literal) breaks downstream crates that don't use
`..Default::default()`. `crates/record-evidence/src/lib.rs` has a test helper
`base_report()` that constructs `InstallReport { ... }` field-by-field, so a new
field is a hard `E0063: missing field` compile error there — surfaced by the
`Rust Tests (stibbons)` CI job, NOT by `cargo test -p luggage` (#644).

**Why:** `cargo test -p luggage` only compiles the luggage crate + its own
tests. record-evidence and stibbons are separate workspace members; their test
code isn't compiled until you build the whole workspace.

**How to apply:** when changing a shared pub type, ALWAYS run
`cargo test --workspace` (and `cargo clippy --workspace --tests -- -D warnings`)
before pushing — not the single-crate `-p` form. Grep for `<TypeName> {`
literals across all crates and update each (e.g. record-evidence's
`base_report()`). When dispatching an implementation agent for a luggage change,
tell it to verify with `--workspace`. Pairs with
[[evidence-run-validates-live-against-db-main]] (wire-shape stays identical via
`skip_serializing_if`, but the Rust constructor still needs the field).
