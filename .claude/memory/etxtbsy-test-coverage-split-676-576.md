---
name: etxtbsy-test-coverage-split-676-576
description: PR
metadata:
  node_type: memory
  type: project
  originSessionId: 3d69e7e3-253a-4c02-a354-ae2d3913bb97
---

The PR #575 deferred-review test gaps for the `run_version_check` ETXTBSY
retry helper (`crates/luggage/src/installer/idempotency.rs`) landed in two
PRs, so don't re-add the earlier half:

- **#676** (commit b571aaeb) already added: retry-**exhaustion** unit tests
  (`run_version_check_propagates_etxtbsy_after_exhausting_retries`,
  `already_installed_returns_false_when_etxtbsy_never_clears`) + the stderr
  parallel regression. Covers gap 1(c).
- **#576** (PR #684) added the remainder: `run_version_check` direct tests for
  1(a) retry-then-succeed and 1(b) immediate non-ETXTBSY return; the
  `validate::check` ETXTBSY→`ValidationFailed` mapping test (gap 2); a parallel
  `validate::check` regression (gap 3); and serialized
  `run_with_report_on_success_captures_validate_output` (gap 4).

All held-fd ETXTBSY induction tests are Linux-only — see
[[etxtbsy-held-fd-linux-only]].
