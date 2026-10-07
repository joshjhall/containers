#!/usr/bin/env bash
# Unit tests: CI's gitleaks scanner must match the dev-tools.sh install.
#
# gitleaks/gitleaks-action downloads whatever GITLEAKS_VERSION its env names,
# falling back to a hard-coded 8.24.3. That release predates the scoped
# [[allowlists]] / targetRules that .gitleaks.toml relies on (#876), so CI kept
# failing full-history workflow_dispatch scans while the dev container's newer
# gitleaks reported the same tree clean (#1050). The fix pins the action's
# GITLEAKS_VERSION to lib/features/dev-tools.sh's default, which is the single
# source of truth; this test fails the build when the two diverge, or when the
# pin drops below the first release that honors the scoped allowlists.
#
# When you bump gitleaks: change the dev-tools.sh default — the auto-patch
# updater (bin/lib/update-versions/updaters.sh) rewrites both pins together.

set -euo pipefail

# Source test framework
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "gitleaks version sync tests (#1050)"

DEV_TOOLS="$PROJECT_ROOT/lib/features/dev-tools.sh"
CI_WORKFLOW="$PROJECT_ROOT/.github/workflows/ci.yml"

# First gitleaks release where both scoped allowlist forms in .gitleaks.toml
# (regexTarget value allowlist + targetRules path allowlist) take effect.
GITLEAKS_FLOOR="8.29.0"

# _dev_tools_version <file>
# Prints the X.Y.Z default from `GITLEAKS_VERSION="${GITLEAKS_VERSION:-X.Y.Z}"`.
_dev_tools_version() {
    command grep -E '^GITLEAKS_VERSION=' "$1" |
        command sed -E 's/.*:-([^}]*)}.*/\1/'
}

# _ci_pins <file>
# Prints every `GITLEAKS_VERSION: "X.Y.Z"` value in a workflow, one per line.
_ci_pins() {
    command grep -E '^[[:space:]]*GITLEAKS_VERSION:' "$1" |
        command sed -E 's/.*GITLEAKS_VERSION:[[:space:]]*"?([^"[:space:]]*)"?.*/\1/' || true
}

DEV_VERSION="$(_dev_tools_version "$DEV_TOOLS")"

test_source_of_truth_parses() {
    assert_matches "$DEV_VERSION" '^[0-9]+\.[0-9]+\.[0-9]+$' \
        "dev-tools.sh GITLEAKS_VERSION default must be X.Y.Z (got '$DEV_VERSION')"
}

# Exactly one pin: zero means the action silently falls back to 8.24.3; more
# than one means a second gitleaks step this test would only half-check.
test_ci_sets_exactly_one_pin() {
    local count
    count="$(_ci_pins "$CI_WORKFLOW" | command grep -c . || true)"
    assert_equals "1" "$count" \
        "ci.yml must set GITLEAKS_VERSION on the gitleaks-action step exactly once"
}

test_ci_pin_matches_dev_tools() {
    local pin
    pin="$(_ci_pins "$CI_WORKFLOW" | command head -n 1)"
    assert_equals "$DEV_VERSION" "$pin" \
        "ci.yml GITLEAKS_VERSION ($pin) must equal dev-tools.sh's default ($DEV_VERSION)"
}

test_ci_pin_meets_floor() {
    local pin lowest
    pin="$(_ci_pins "$CI_WORKFLOW" | command head -n 1)"
    lowest="$(printf '%s\n%s\n' "$GITLEAKS_FLOOR" "$pin" | command sort -V | command head -n 1)"
    assert_equals "$GITLEAKS_FLOOR" "$lowest" \
        "ci.yml GITLEAKS_VERSION ($pin) must be >= $GITLEAKS_FLOOR, or .gitleaks.toml's scoped allowlists are ignored"
}

# The updater must move both pins, or the first weekly auto-patch that bumps
# gitleaks red-lights its own branch on the tests above. Run the real gitleaks
# case against a scratch PROJECT_ROOT holding copies of both files.
test_updater_bumps_both_pins() {
    local root="$TEST_SCRATCH_BASE/gitleaks-sync-root"
    /bin/mkdir -p "$root/lib/features" "$root/.github/workflows"
    /bin/cp "$DEV_TOOLS" "$root/lib/features/dev-tools.sh"
    /bin/cp "$CI_WORKFLOW" "$root/.github/workflows/ci.yml"

    local rc=0
    (
        source "$PROJECT_ROOT/bin/lib/common.sh"
        source "$PROJECT_ROOT/bin/lib/version-utils.sh"
        source "$PROJECT_ROOT/bin/lib/update-versions/updaters.sh"
        PROJECT_ROOT="$root"
        # shellcheck disable=SC2034 # consumed by update_version()
        DRY_RUN=false
        update_version "gitleaks" "$DEV_VERSION" "99.1.2" "dev-tools.sh"
    ) >/dev/null 2>&1 || rc=$?

    local dev_after ci_after
    dev_after="$(_dev_tools_version "$root/lib/features/dev-tools.sh")"
    ci_after="$(_ci_pins "$root/.github/workflows/ci.yml" | command head -n 1)"
    /bin/rm -rf "$root"

    assert_equals "0" "$rc" "update_version gitleaks must succeed"
    assert_equals "99.1.2" "$dev_after" "updater must bump dev-tools.sh GITLEAKS_VERSION"
    assert_equals "99.1.2" "$ci_after" "updater must bump ci.yml GITLEAKS_VERSION alongside dev-tools.sh"
}

# The pin only works inside the gitleaks-action step's own env block: moved to
# another step or job, the action falls back to 8.24.3 while the grep-based
# tests above still pass. Walk from the `uses:` line to the next step and
# require the pin to appear in between.
test_ci_pin_is_on_the_gitleaks_step() {
    local in_step
    in_step="$(command awk '
        /uses: gitleaks\/gitleaks-action@/ { inside = 1; next }
        inside && /^[[:space:]]*- (name|uses):/ { inside = 0 }
        inside && /^[[:space:]]*GITLEAKS_VERSION:/ { found = 1 }
        END { print found ? "yes" : "no" }
    ' "$CI_WORKFLOW")"
    assert_equals "yes" "$in_step" \
        "GITLEAKS_VERSION must be set in the gitleaks-action step's env, not elsewhere in ci.yml"
}

run_test test_source_of_truth_parses "dev-tools.sh GITLEAKS_VERSION default parses"
run_test test_ci_sets_exactly_one_pin "ci.yml sets GITLEAKS_VERSION exactly once"
run_test test_ci_pin_is_on_the_gitleaks_step "ci.yml pin sits on the gitleaks-action step"
run_test test_ci_pin_matches_dev_tools "ci.yml pin equals dev-tools.sh default"
run_test test_ci_pin_meets_floor "ci.yml pin is >= $GITLEAKS_FLOOR"
run_test test_updater_bumps_both_pins "updater bumps both pins together"

generate_report
