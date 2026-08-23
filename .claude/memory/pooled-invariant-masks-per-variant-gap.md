---
name: pooled-invariant-masks-per-variant-gap
description: A catalog invariant checked across a union of variants hides a variant that has nothing; check per-variant
metadata:
  node_type: memory
  type: feedback
  originSessionId: a08c0b91-6fba-4054-a6e8-e6a66349d9a8
  modified: 2026-08-22T23:30:07.577Z
---

`crates/luggage/tests/catalog_component_completeness.rs` asserted every rust
version carried the full rustup component set — but pooled `post_install`
components across **all** of a version's `install_methods` before comparing.

The shipped `1.97.x` entries had the complete set on the debian/ubuntu/rhel
method and **no `post_install` at all** on the alpine one. The union still saw
all four components, so the invariant passed while every Alpine build installed
`rustc`/`cargo` with no `clippy`, `rustfmt`, or `rust-analyzer` — the #740
half-install footgun, alive on one platform. Fixed in #815 to check each method
independently and name the offending method on failure.

**Why:** the resolver picks exactly ONE install method at install time based on
the target platform. An invariant about "what gets installed" must therefore
hold for each method separately; a union answers a question nobody asks.

**How to apply:** when an invariant covers a set of alternatives that are
selected between at runtime (install methods, platform arms, feature variants,
config profiles), assert it per-alternative. A `flat_map` over the alternatives
before the check is the smell. Then prove the tightened check has teeth by
deleting the field from one alternative and confirming it fails — a pooled
check that never fired looks identical to a passing one.

Related: [[vendored-catalog-drift-gate]].
