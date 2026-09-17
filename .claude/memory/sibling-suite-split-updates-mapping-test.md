---
name: sibling-suite-split-updates-mapping-test
description: Splitting a tests/unit/runtime/ suite into a new sibling breaks run-changed-tests.sh's exact-count assertion
metadata:
  type: project
---

`tests/unit/run-changed-tests.sh` pins the `lib/runtime/*` → test-path mapping
by **name AND exact count** (`assert_equals "N" "$count"`). Adding a new
`workspace-fs-health-*.sh` sibling makes the glob emit N+1 and the suite fails
with `Expected: '4' / Actual: '5'` — in a file the split never touched.

That is the assertion working as designed: a loose `count > 1` would stay green
if the glob silently dropped a suite, which is the coverage-narrows-silently
failure the arm exists to prevent (see [[skips-render-as-passes]]).

**Why:** the failure surfaces far from the edit, so it reads like an unrelated
break and invites a rebase-blame detour ([[rebase-before-blaming-your-change]])
instead of a three-line fix.

**How to apply:** when splitting a suite under `tests/unit/runtime/`, update
`tests/unit/run-changed-tests.sh` in the same commit — add an
`assert_contains` for the new sibling, bump the count, and update the prose
comment naming how many suites cover the script. Verify the mapping actually
emits the new path, not just that the count matches.
