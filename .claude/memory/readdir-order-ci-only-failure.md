---
name: readdir-order-ci-only-failure
description: "a test that fails deterministically on one CI runner but passes locally can be find/readdir order, not your branch or main"
metadata:
  node_type: memory
  type: project
  originSessionId: e4674d78-72f5-4cef-9910-f898bf737dd9
  modified: 2026-10-19T17:31:39.017Z
---

A suite the PR never touched failed `Run Tests` twice on PR #1338 (same
assertion both attempts, so not a flake), passed 3/3 locally, and passed in the
same branch's earlier CI run. main had not moved, so [[rebase-before-blaming-your-change]]
did not apply. Cause: the librarian symlink prune in
`lib/features/claude-code-setup.sh` deleted links *while walking* `find`'s
output, so `chain -> .codegraph` survived whenever `.codegraph` was listed
first. `find` order is filesystem readdir order, which differs by runner.
Fixed 2026-10-19 by resolving every link before deleting any.

**Why:** a mutate-while-iterating loop over `find` output is order-dependent,
and nothing locally reproduces the runner's order, so it reads as "CI is flaky".

**How to apply:** when a deterministic CI-only failure lands in code that walks
`find`/a directory listing, reproduce by forcing both orders (`sort -z` vs
`sort -rz` on the list, or a stubbed `find` that prints a fixed order) on a
scratch tree before retrying. Pin the bad order in a test with a `find` stub,
since real `find` cannot be made to produce it. Related:
[[assertions-must-discriminate]], [[mutation-checks-on-scratch-copies]].
