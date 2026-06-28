---
name: pre-push-skips-network-tests
description: Pre-push gate skips network-bound tests via SKIP_NETWORK_TESTS; CI still runs them
metadata:
  node_type: memory
  type: project
  originSessionId: dae605c8-c0f0-4b69-b755-420c06b40138
---

The lefthook **pre-push** hook runs `tests/run_changed_tests.sh`, which maps
foundational files (`tests/framework.sh`, `tests/framework/*`, `Dockerfile`) to
`ALL` and execs the whole unit suite. That suite includes live-network tests
(`tests/unit/bin/check-versions.sh` curls `api.github.com` per tool), which
serialized across concurrent golems and stalled pushes ~20 min (#615).

Fix: `run_changed_tests.sh` exports **`SKIP_NETWORK_TESTS=1`**; live tests
consult `network_tests_disabled()` (defined + `export -f`'d in
`tests/framework.sh`) and `skip_test`. **CI is unaffected** because it invokes
`tests/run_unit_tests.sh` directly (and `just test`), leaving the flag unset —
so the full network matrix still runs there. The split is: pre-push = offline
gate, CI = full checks.

**Why:** keeps routine pushes fast/offline-safe without a cross-worktree cache
or push lock. **How to apply:** any new live-network unit test must guard with
`if network_tests_disabled; then skip_test ...; return; fi`, else it re-enters
the push gate. `tests/unit/run-changed-tests.sh` is the regression guard, and a
`map_to_test()` arm runs it when the runner is edited.

Relates to [[worktree-push-hooks-gitignore]] and
[[parallel-automation-golem-initiative]].
