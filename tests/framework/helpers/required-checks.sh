#!/usr/bin/env bash
# Shared yq helpers for the branch-protection required-check suites.
#
# SOURCE-ONLY — this file defines no tests and must never be executed directly.
# It lives under tests/framework/ rather than tests/unit/ because
# run_unit_tests.sh discovers suites with `find tests/unit -name "*.sh"`, so a
# fragment there would run as a suite with zero tests (same reasoning as
# tests/framework/helpers/workspace-fs-health.sh).
#
# Sourced by:
#   tests/unit/required-checks.sh          (manifest ↔ workflow resolution, #904/#910/#919)
#   tests/unit/required-checks-pr-tier.sh  (pr-tier rollup + label mirror, #909/#1099)
#
# Source it AFTER framework.sh + init_test_framework — run_yq writes scratch
# under TEST_TEMP_DIR / TEST_SCRATCH_BASE.
#
# Split out of required-checks.sh in issue #1271.

# yq is the parser for the trigger-shape tests. Regex cannot reliably tell
# a `paths:` under `pull_request:` from one under `push:`, and getting that
# backwards is exactly the silent-pass these suites exist to prevent.
#
# Absence is fatal in CI and a skip locally: ci.yml installs yq explicitly, so
# a missing binary there means the install step regressed. A test that quietly
# skips in CI renders as a pass and guards nothing (#768).
require_yq() {
    if command -v yq >/dev/null 2>&1; then
        return 0
    fi
    if [ "${CI:-false}" = "true" ]; then
        assert_true false \
            "yq is required in CI — required-context checks cannot silently skip (see .github/workflows/ci.yml)"
    else
        skip_test "yq not available — skipping required-context workflow parsing"
    fi
    return 1
}

# Run `yq -r "$1" "$2"` and print its stdout, but FAIL LOUD when yq itself
# fails (#919).
#
# The bug this replaces: every call site here was written `yq … 2>/dev/null`,
# several with a trailing `|| true`. That folds a yq failure into an empty
# result, and an empty result is a meaningful answer to every query in this
# file — so a transient blip renders as a confident wrong verdict in BOTH
# directions. On PR #915 it reported `no job with this name exists` for a job
# that plainly existed, then passed on a plain rerun of the same SHA; in
# test_context_workflows_have_no_pull_request_path_filters the same swallowing
# produces the mirror image, a test that PASSES without having checked anything.
#
# The exit code already discriminates cleanly, which is why this is a small fix:
# malformed YAML exits non-zero, while every legitimate negative — `.jobs`
# absent, a recursive descent matching nothing, a push-only workflow answering
# `has("pull_request")` — exits 0. So a non-zero exit is never a legitimate
# "no such job". It is either a malformed workflow (worth failing on) or a
# transient (worth reporting), and neither should render as drift.
#
# Returns yq's exit code. On failure, prints a diagnostic naming the file, the
# exit code, and yq's own stderr. Callers MUST propagate rather than swallow.
run_yq() {
    local expr="$1" file="$2" out err rc=0
    # Scratch under the per-test temp dir, falling back to the suite scratch
    # base if a caller ever runs outside a test body. NEVER tests/results/ —
    # that path is an incoherent FUSE mount whose write-then-read drops ~0.75%
    # of operations (#821), which would reintroduce exactly this flake class.
    err="${TEST_TEMP_DIR:-${TEST_SCRATCH_BASE:-/tmp}}/yq-stderr.$$"
    out=$(yq -r "$expr" "$file" 2>"$err") || rc=$?
    if [ "$rc" -ne 0 ]; then
        # To STDERR, deliberately: every caller captures stdout in a command
        # substitution, so a diagnostic written there would be swallowed into
        # the very variable whose emptiness we are trying to explain.
        {
            /usr/bin/echo "  yq failed on $(/usr/bin/basename "$file") (exit $rc) — this is NOT 'no such job':"
            /usr/bin/sed 's/^/      /' "$err" 2>/dev/null || true
        } >&2
        /usr/bin/rm -f "$err"
        return "$rc"
    fi
    /usr/bin/rm -f "$err"
    /usr/bin/printf '%s\n' "$out"
}
