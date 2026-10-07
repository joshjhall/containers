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

# _run_updater <root> <dry_run> — run the real gitleaks updater case against a
# scratch PROJECT_ROOT, bumping to 99.1.2. Prints the return code.
_run_updater() {
    local rc=0
    (
        source "$PROJECT_ROOT/bin/lib/common.sh"
        source "$PROJECT_ROOT/bin/lib/version-utils.sh"
        source "$PROJECT_ROOT/bin/lib/update-versions/updaters.sh"
        PROJECT_ROOT="$1"
        # shellcheck disable=SC2034 # consumed by update_version()
        DRY_RUN="$2"
        update_version "gitleaks" "$DEV_VERSION" "99.1.2" "dev-tools.sh"
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

    assert_not_equals "0" "$rc" "update_version gitleaks must fail when ci.yml is missing"
    assert_equals "$DEV_VERSION" "$dev_after" "dev-tools.sh must be left untouched when ci.yml is missing"
}

# sed exits 0 on no match, so a reformatted pin line (here: unquoted) must be
# caught by the post-write check rather than reported as a successful bump.
test_updater_fails_on_unmatched_ci_pin() {
    local root rc
    root="$(_scratch_root gitleaks-sync-reformat)"
    command sed -i -E 's/(GITLEAKS_VERSION: *)"([^"]*)"/\1\2/' "$root/.github/workflows/ci.yml"
    rc="$(_run_updater "$root" false)"
    /bin/rm -rf "$root"

    assert_not_equals "0" "$rc" "update_version gitleaks must fail when the ci.yml pin line did not match"
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
run_test test_updater_fails_cleanly_without_ci_yml "updater fails before writing when ci.yml is missing"
run_test test_updater_fails_on_unmatched_ci_pin "updater fails when the ci.yml pin did not match"
run_test test_updater_dry_run_writes_nothing "updater dry run writes nothing"

generate_report
