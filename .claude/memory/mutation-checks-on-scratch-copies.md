---
name: mutation-checks-on-scratch-copies
description: "Mutation-testing a guard means mutating a mktemp copy and pointing the checker at it — never sed -i / cp over a tracked file with a \"restore after\" step"
metadata:
  node_type: memory
  type: feedback
  originSessionId: a5119337-03a4-4576-8119-a6b964540063
  modified: 2026-10-03T22:09:50.117Z
---

When proving a test discriminates (break the code, watch it fail, restore), mutate
a **scratch copy** under `mktemp -d` and pass that path to the checker. Never edit
the tracked file in place with `sed -i` / `cp mutated real` and a trailing
`cp backup real` — any failure between the two (a `set -e` abort, a killed
process, an auto-denied permission prompt mid-chain) leaves the tracked file
mutated, and a golem may then commit it.

**Why:** 2026-10-03, golem-1008 (#1008) proposed exactly that chain against the
worktree's `Dockerfile` for its ARG-order mutation checks; the orchestrator
declined it and redirected to scratch copies. Plans approved with "mutate a
scratch copy" drifted to in-place mutation at execution time.

**How to apply:** design checkers to take a file path argument (as #1008's
`node_condition_arg_order_errors <dockerfile>` does) so a mutation is just a
different path. When brokering a golem's permission prompt, decline any command
that `sed -i`/`cp`s over a tracked file for a verification step. Related:
[[assertions-must-discriminate]], [[grep-pin-is-not-behavioral-coverage]].
