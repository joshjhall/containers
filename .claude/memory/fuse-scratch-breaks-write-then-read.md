---
name: fuse-scratch-breaks-write-then-read
description: Test scratch on the FUSE-mounted repo loses write-then-read coherency ~0.75% of ops — reddened a random unit suite per run; scratch must live off-repo under TEST_SCRATCH_BASE
metadata:
  node_type: memory
  type: project
  originSessionId: 5f70bf8c-e84d-4e92-804d-a9a2f915b062
  modified: 2026-08-23T19:45:02.789Z
---

`tests/run_unit_tests.sh` is **strictly sequential** (a plain `for` loop, no `&`,
no `xargs -P`), so "concurrent suites collided in a shared temp dir" can never
explain an intermittent single-suite failure there. #821 was misdiagnosed three
times along that line before the real cause was found.

The cause is **filesystem coherency**. The repo is mounted virtiofs plus a
bindfs FUSE overlay, and `tests/results/` sits inside it. A single-process,
zero-concurrency "write a file, then immediately grep it" loop misses
**3/400 (~0.75%)** under `tests/results/` and **0/400** under `/tmp`. Across ~46
suites × dozens of write-then-read assertions that compounds to a failure every
2–4 runs, landing on a *different* suite each time and always passing when
re-run standalone. (#824/#818 measured the same thing independently: 6 losses in
3200 on FUSE, 0 in 3200 on overlay.)

**Why:** Since #821 the framework provides `TEST_SCRATCH_BASE` (module scope in
`tests/framework.sh`) — off-repo, fstype-probed against a FUSE/network deny
list, per-uid parent at mode 700, unique per suite process, env-overridable.
`RESULTS_DIR` means reports and CI artifacts only; `.github/workflows/ci.yml`
uploads `tests/results/`.

**How to apply:** Build every scratch path from `$TEST_SCRATCH_BASE`, never from
`$RESULTS_DIR`. Two guards in `tests/unit/test_framework_scratch_base.sh` enforce
it — one over `tests/unit/`, one over `docs/development/testing.md` and
`.claude/skills/test-framework-reference/SKILL.md`, because those templates are
what gets copied when writing a new suite. When an assertion fails on a file the
test *just generated*, and the pattern is demonstrably present in the source,
suspect the scratch copy and the filesystem under it — not the source.

Two traps worth remembering:

- Cleanup must be the age-based reaper (`tf_reap_stale_temp_dirs`), not an EXIT
  trap: two suites under `tests/unit/observability/` install their own
  `trap cleanup EXIT` which silently replaces the framework's, and no trap
  survives `kill -9`.
- `mkdir -m 700 -p a/b` applies the mode only to the **deepest** component
  (SC2174), so the parent — the directory that actually needs the tight mode in
  a world-writable tmp root — is left at umask.

Related: [[stale-symlink-attrs-virtiofs]], [[case-insensitive-mount-shared-inode]],
[[hermetic-fixture-tests-need-git-identity]], [[bash-env-breaks-path-stubs]].
