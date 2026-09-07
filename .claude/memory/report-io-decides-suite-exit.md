---
name: report-io-decides-suite-exit
description: "a suite's LAST command sets its exit status — report/artifact I/O there turns a mount hiccup into a fake test failure"
metadata:
  type: project
---

`generate_report` is the final command of every shell suite, and suites run
under `set -e`, so **whatever it returns becomes the suite's exit status**. It
used to end with a bare `... | command tee "$report_file"` writing into
`$RESULTS_DIR` (`tests/results/`, on the incoherent FUSE mount from
[[results-dir-fuse-incoherent]]). A failed artifact write therefore exited
non-zero on a suite with **0 failed tests**.

**Signature:** the harness reports a suite as ERROR / "failed to run", the
suite's own report says `Failed: 0`, and it is green on re-run. Do not go
hunting for a broken test — there isn't one. Hit for real on 2026-09-07 during
a version sweep: conform-scopes blocked a push while reporting 5 passed / 0
failed.

Measured, write-then-read, 8 procs x 400: **1 lost / 3200** under
`tests/results`, **0 / 3200** under `/tmp`.

Fixed (`tests/framework.sh`): reports stage on a coherent fs
(`tf_report_staging_dir`) then copy into `$RESULTS_DIR`; the tee and the copy
are both non-fatal; the result comparison stays last. Guarded by
`tests/unit/test_framework_report_exit.sh`, which covers all four quadrants
(green/red x working/broken report path) — the red-with-broken-path case is
what stops a "fix" that just makes `generate_report` always succeed, which
would disable the whole gate.

**Generalize:** in any script whose exit code is a verdict, nothing fallible
may run after the verdict is computed. Logging, artifact upload, cleanup and
notification all belong before it, or explicitly neutralized with `|| true`.
Related: [[skips-render-as-passes]], [[zero-checks-is-not-green]] — all three
are "an infrastructure outcome got read as a test outcome".
