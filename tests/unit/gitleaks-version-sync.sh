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

# update_version()'s "held, nothing written" code, read from the source so the
# refusal tests below cannot drift from it.
RC_INVALID_VERSION="$(command sed -nE 's/^RC_INVALID_VERSION=([0-9]+).*/\1/p' \
    "$PROJECT_ROOT/bin/lib/update-versions/updaters.sh")"

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

# _run_updater <root> <dry_run> [version] — run the real gitleaks updater case
# against a scratch PROJECT_ROOT (default bump: 99.1.2). Prints the return code.
_run_updater() {
    local rc=0
    (
        source "$PROJECT_ROOT/bin/lib/common.sh"
        source "$PROJECT_ROOT/bin/lib/version-utils.sh"
        source "$PROJECT_ROOT/bin/lib/update-versions/updaters.sh"
        PROJECT_ROOT="$1"
        # shellcheck disable=SC2034 # consumed by update_version()
        DRY_RUN="$2"
        update_version "gitleaks" "$DEV_VERSION" "${3:-99.1.2}" "dev-tools.sh"
    ) >/dev/null 2>&1 || rc=$?
    printf '%s\n' "$rc"
}

# _scratch_root <name> — copy dev-tools.sh and ci.yml into a fresh scratch
# PROJECT_ROOT and print its path.
_scratch_root() {
    local root="$TEST_SCRATCH_BASE/$1"
    /bin/mkdir -p "$root/lib/features" "$root/.github/workflows"
    /bin/cp "$DEV_TOOLS" "$root/lib/features/dev-tools.sh"
    /bin/cp "$CI_WORKFLOW" "$root/.github/workflows/ci.yml"
    printf '%s\n' "$root"
}

# The updater must move both pins, or the first weekly auto-patch that bumps
# gitleaks red-lights its own branch on the tests above.
test_updater_bumps_both_pins() {
    local root rc dev_after ci_after
    root="$(_scratch_root gitleaks-sync-ok)"
    rc="$(_run_updater "$root" false)"
    dev_after="$(_dev_tools_version "$root/lib/features/dev-tools.sh")"
    ci_after="$(_ci_pins "$root/.github/workflows/ci.yml" | command head -n 1)"
    /bin/rm -rf "$root"

    assert_equals "0" "$rc" "update_version gitleaks must succeed"
    assert_equals "99.1.2" "$dev_after" "updater must bump dev-tools.sh GITLEAKS_VERSION"
    assert_equals "99.1.2" "$ci_after" "updater must bump ci.yml GITLEAKS_VERSION alongside dev-tools.sh"
}

# A missing ci.yml must fail the bump BEFORE dev-tools.sh is touched, or the
# auto-patch branch carries a half-applied, divergent pair.
test_updater_fails_cleanly_without_ci_yml() {
    local root rc dev_after
    root="$(_scratch_root gitleaks-sync-noci)"
    /bin/rm -f "$root/.github/workflows/ci.yml"
    rc="$(_run_updater "$root" false)"
    dev_after="$(_dev_tools_version "$root/lib/features/dev-tools.sh")"
    /bin/rm -rf "$root"

    assert_equals "$RC_INVALID_VERSION" "$rc" "a missing ci.yml must hold the bump (RC_INVALID_VERSION), not fail the run"
    assert_equals "$DEV_VERSION" "$dev_after" "dev-tools.sh must be left untouched when ci.yml is missing"
}

# _unquote_pin <file> <pin-regex> — strip the quotes from a pin line so it no
# longer matches the updater's expected shape. Portable: no `sed -i`.
_unquote_pin() {
    command sed -E "s/^($2)\"([^\"]*)\"/\\1\\2/" "$1" >"$1.tmp" && /bin/mv "$1.tmp" "$1"
}

# sed exits 0 on no match, so a reformatted pin line in EITHER file must fail
# the bump before anything is written, rather than leaving one pin bumped alone.
test_updater_fails_on_unmatched_ci_pin() {
    local root rc dev_after
    root="$(_scratch_root gitleaks-sync-reformat-ci)"
    _unquote_pin "$root/.github/workflows/ci.yml" '[[:space:]]*GITLEAKS_VERSION: *'
    rc="$(_run_updater "$root" false)"
    dev_after="$(_dev_tools_version "$root/lib/features/dev-tools.sh")"
    /bin/rm -rf "$root"

    assert_equals "$RC_INVALID_VERSION" "$rc" "a reformatted ci.yml pin must hold the bump (RC_INVALID_VERSION)"
    assert_equals "$DEV_VERSION" "$dev_after" "dev-tools.sh must be left untouched when the ci.yml pin cannot be rewritten"
}

test_updater_fails_on_unmatched_dev_tools_pin() {
    local root rc ci_same=yes
    root="$(_scratch_root gitleaks-sync-reformat-dev)"
    _unquote_pin "$root/lib/features/dev-tools.sh" 'GITLEAKS_VERSION='
    rc="$(_run_updater "$root" false)"
    command cmp -s "$CI_WORKFLOW" "$root/.github/workflows/ci.yml" || ci_same=no
    /bin/rm -rf "$root"

    assert_equals "$RC_INVALID_VERSION" "$rc" "a reformatted dev-tools.sh pin must hold the bump (RC_INVALID_VERSION)"
    assert_equals "yes" "$ci_same" "ci.yml must be left untouched when the dev-tools.sh pin cannot be rewritten"
}

# validate_version lets any suffix through after -/+, and $latest is written
# into ci.yml's quoted YAML value. Anything but plain X.Y.Z must be refused
# before either file is touched.
test_updater_refuses_non_semver_version() {
    local root rc dev_same=yes ci_same=yes
    root="$(_scratch_root gitleaks-sync-badver)"
    rc="$(_run_updater "$root" false '9.9.9-x"y')"
    command cmp -s "$DEV_TOOLS" "$root/lib/features/dev-tools.sh" || dev_same=no
    command cmp -s "$CI_WORKFLOW" "$root/.github/workflows/ci.yml" || ci_same=no
    /bin/rm -rf "$root"

    assert_equals "$RC_INVALID_VERSION" "$rc" "a non-X.Y.Z version must hold the bump (RC_INVALID_VERSION)"
    assert_equals "yes" "$dev_same" "dev-tools.sh must be untouched after a refused version"
    assert_equals "yes" "$ci_same" "ci.yml must be untouched after a refused version"
}

# A write that fails after the preflight passes must surface as a real failure
# (RC_UPDATE_FAILED -> update-versions exit 3), never as a successful bump that
# left the pins divergent. Making the workflows dir read-only lets the preflight
# (a read) pass and the dev-tools.sh write land, then fails the real ci.yml
# write: the half-update exit 3 exists to catch. Skipped as root, where the
# read-only bit does not stop writes.
test_updater_reports_failed_write() {
    if [ "$(command id -u)" = "0" ]; then
        skip_test "running as root: a read-only directory does not block writes"
        return
    fi
    local root rc expected
    root="$(_scratch_root gitleaks-sync-writefail)"
    expected="$(command sed -nE 's/^RC_UPDATE_FAILED=([0-9]+).*/\1/p' \
        "$PROJECT_ROOT/bin/lib/update-versions/updaters.sh")"
    /bin/chmod a-w "$root/.github/workflows"
    rc="$(_run_updater "$root" false)"
    /bin/chmod u+w "$root/.github/workflows"
    /bin/rm -rf "$root"

    assert_equals "$expected" "$rc" "a failed pin write must return RC_UPDATE_FAILED, not success"
}

# sed_inplace must return sed's own status. Its cleanup loop used to run last,
# so a failed sed reported 0 and every `sed_inplace ... || return` guard in
# rust-pins.sh and gitleaks-pins.sh was dead code.
test_sed_inplace_propagates_sed_failure() {
    local rc=0
    (
        source "$PROJECT_ROOT/bin/lib/common.sh"
        source "$PROJECT_ROOT/bin/lib/version-utils.sh"
        source "$PROJECT_ROOT/bin/lib/update-versions/updaters.sh"
        # shellcheck disable=SC2034 # read by sed_inplace()
        DRY_RUN=false
        sed_inplace 's/a/b/' "$TEST_SCRATCH_BASE/does-not-exist/file"
    ) >/dev/null 2>&1 || rc=$?
    local expected
    expected="$(command sed -nE 's/^RC_UPDATE_FAILED=([0-9]+).*/\1/p' \
        "$PROJECT_ROOT/bin/lib/update-versions/updaters.sh")"
    assert_equals "$expected" "$rc" "sed_inplace must report a failed sed as RC_UPDATE_FAILED"
}

test_updater_dry_run_writes_nothing() {
    local root rc dev_same=yes ci_same=yes
    root="$(_scratch_root gitleaks-sync-dry)"
    rc="$(_run_updater "$root" true)"
    command cmp -s "$DEV_TOOLS" "$root/lib/features/dev-tools.sh" || dev_same=no
    command cmp -s "$CI_WORKFLOW" "$root/.github/workflows/ci.yml" || ci_same=no
    /bin/rm -rf "$root"

    assert_equals "0" "$rc" "a dry-run gitleaks update must succeed"
    assert_equals "yes" "$dev_same" "a dry run must leave dev-tools.sh byte-identical"
    assert_equals "yes" "$ci_same" "a dry run must leave ci.yml byte-identical"
}

# The pin only works inside the gitleaks-action step's own env block: moved to
# another step or job, the action falls back to 8.24.3 while the grep-based
# tests above still pass. Walk from the `uses:` line to the next step and
# require the pin to appear in between.
test_ci_pin_is_on_the_gitleaks_step() {
    local in_step
    in_step="$(command awk '
        /uses: gitleaks\/gitleaks-action@/ { inside = 1; next }
        inside && /^[[:space:]]*- / { inside = 0 }
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
run_test test_updater_fails_cleanly_without_ci_yml "updater fails before writing when ci.yml is missing"
run_test test_updater_fails_on_unmatched_ci_pin "updater fails before writing on a reformatted ci.yml pin"
run_test test_updater_fails_on_unmatched_dev_tools_pin "updater fails before writing on a reformatted dev-tools.sh pin"
run_test test_updater_refuses_non_semver_version "updater refuses a non-X.Y.Z version before writing"
run_test test_updater_reports_failed_write "updater reports a failed pin write as RC_UPDATE_FAILED"
run_test test_sed_inplace_propagates_sed_failure "sed_inplace returns sed's failure status"
run_test test_updater_dry_run_writes_nothing "updater dry run writes nothing"

generate_report
