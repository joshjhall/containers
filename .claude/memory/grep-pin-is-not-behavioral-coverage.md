---
name: grep-pin-is-not-behavioral-coverage
description: "A grep that pins a guard's source text catches drift but proves nothing about behavior; pair it with a test that sources the script and inspects the outcome"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 423335ae-5152-4c86-8467-e37b725dadd0
  modified: 2026-09-07T17:55:52.077Z
---

A `command grep -q "if is_debian_version 12 && ! is_debian_version 13"` over a
feature script asserts the guard's **text**, not its **decision**. It cannot
tell a correct rewrite from a broken one, so it reads as coverage while leaving
the composed condition unverified (#937).

**Why:** the two failure modes are orthogonal, and one test cannot cover both.
Measured on the #937 cleanup guard:

| Mutation | grep pin | runtime test |
| --- | --- | --- |
| semantics broken (`12` → `11`) | FAIL | FAIL |
| semantics-preserving rewrite to `[ "$(get_debian_major_version)" = "12" ]` | FAIL | PASS |

The second row is the point: the pin fires on a change that broke nothing, and
would equally stay silent if the string were preserved while behavior moved.

**How to apply:** when a guard's correctness matters, source the real script
with its inputs stubbed and inspect the *outcome* — for a script that builds an
array, `command echo "PKGS:${_remove_pkgs[*]}"` after sourcing. Drive every
branch (in-range / below / above / `unknown`), and add a positive control
asserting the version-independent members are still present, or the negative
cases pass on an empty array. Keep the pin **as well** when call sites must
agree across files — it catches cross-file drift the runtime test cannot see.

Beware the near-miss: a boundary test for a *different* function
(`apt_install_conditional`) does not cover a guard that composes
`is_debian_version` calls directly, even when they sit lines apart and read as
the same concern. Check what the guard actually calls.

Related: [[assertions-must-discriminate]] (the general rule — delete the guarded
line and confirm THAT test fails), and
[[discriminate-rule-has-no-fixed-point-on-scaffolding]] (when adding another
verification layer stops paying).
