---
name: tests-share-results-dir
description: "All unit suites share tests/results/; fixed-name TEST_TEMP_DIR collides, unique names leak — both bite"
metadata:
  node_type: memory
  type: project
  originSessionId: 5a660d70-0c9f-4e56-8853-4a046932c007
  modified: 2026-08-23T14:01:54.990Z
---

Every unit suite puts its `TEST_TEMP_DIR` under the **shared** `$RESULTS_DIR`
(`tests/results/`, gitignored) and `rm -rf`s it in teardown after **every**
test. That one shared directory causes two opposite failures, and fixing one
worsens the other:

- **Fixed scratch-dir names collide.** Two suites running concurrently delete
  each other's trees mid-run. Reproduce deterministically by starting two at
  once (`dev-tools` + `project-health-check` reliably reddened one). The symptom
  reads like flakiness — the failing suite moves between runs and always passes
  standalone — which is why it was misdiagnosed three times.
- **Unique scratch-dir names leak.** With a per-test suffix, a missed teardown
  leaks a *new* directory instead of reusing one name: ~1,400 per full run,
  unbounded. One tree reached 19,910 directories / 11MB.

Both handled as of #817 (PR #823): suites use `$$-$(date +%s%N)` (the convention
44 suites already followed — per-test, not per-process), and
`tf_reap_stale_temp_dirs` in `tests/framework.sh` reaps top-level scratch dirs
older than 60 minutes at init. The age cutoff is what makes it safe against a
concurrently running suite, whose dirs are seconds old.

**A separate intermittent single-suite failure survives all of this** — see
**#821**. It predates the work, moves between suites, and passes standalone.
**Root-caused as of #818 / PR #824: the workspace FUSE mount loses
read-after-write under concurrency** — see [[results-dir-fuse-incoherent]]. Do
not assume a red suite in a full run is the collision above; check that first.

Two traps found while building the reaper:

- `command` is a **shell builtin and is invalid inside `find -exec`** — the
  whole expression fails with "No such file or directory". With stderr
  suppressed that is completely silent: the function returns 0 having deleted
  nothing. Use an absolute path (`/bin/rm`) there, not the repo's usual
  `command rm`. Compare [[alpine-hardening-no-coreutils-paths]].
- `find <dir> -maxdepth 1` matches **the root itself**, so `-mindepth 1` is what
  stops a reaper deleting `$RESULTS_DIR`. A test whose sandbox root is
  `mktemp`-fresh never crosses an age cutoff, so it passes against that broken
  implementation — age the root or the assertion is vacuous.

Related: [[hermetic-fixture-tests-need-git-identity]],
[[bash-env-breaks-path-stubs]] — other test-isolation gotchas here.
