---
name: refusal-tests-reach-real-gh
description: "A test of a refusal guard that silently doesn't fire falls through to the real `gh` and files real issues/PRs; run such suites with gh removed from PATH"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 3372ceb2-14a1-4bd8-9f54-5c9903fdba32
  modified: 2026-10-17T23:11:07.765Z
---

When a test exercises a guard that should stop *before* a `gh` call (refuse a
plan, vet a tool id, etc.), a guard that fails to fire doesn't fail the test
cleanly. Execution falls through to the real `gh` and does real things on
GitHub.

**Why:** On containers-db #416 (PR #425) this happened twice. A local end-to-end
run fed a tampered plan to `scanner deliver`, and the failure path filed real
tracking issue #424, which had to be closed by hand. Later, a "swap an install
URL" test replaced a string the generator never produces. The plan therefore
passed re-render and reached `gh pr list`, and it failed only because the temp
repo had no remote.

**How to apply:**

- Before trusting such a suite, run the built test binary with `gh` removed from
  an otherwise *full* `PATH`. Symlink every `PATH` entry except `gh` into a temp
  dir. A minimal `PATH` breaks git, because commit signing needs `ssh-keygen`.
  Edition-2024 Rust makes `env::set_var` unsafe in parallel tests, so isolate at
  the process level instead.
- Run mutation checks under the same `gh`-free `PATH`. A mutated guard is
  exactly the case that reaches `gh`.
- Make tamper tests assert that the tamper changed something
  (`assert_ne!(swapped, original)`); see [[assertions-must-discriminate]].
- Related: [[mock-fidelity-gates-assertions]],
  [[mutation-checks-on-scratch-copies]].
