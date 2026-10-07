#!/usr/bin/env bash
# Unit tests: CI's gitleaks scanner is the checksum-verified dev-tools.sh pin.
#
# CI used to run gitleaks/gitleaks-action, which downloads the gitleaks release
# tarball unverified and falls back to a hard-coded 8.24.3 — a release that
# predates the scoped [[allowlists]] / targetRules .gitleaks.toml relies on
# (#876, #1050). CI now installs gitleaks itself (#1064): it reads the version
# from lib/features/dev-tools.sh — the single source of truth — and verifies
# the download against the SHA256 recorded in lib/checksums.json. This test
# fails the build when ci.yml grows its own version pin again (which would
# drift, and make every gitleaks bump a workflow-file push needing the
# auto-patch token's `workflow` scope), when the verification is removed, or
# when the pinned version has no recorded checksum or drops below the floor.
#
# When you bump gitleaks: change the dev-tools.sh default — auto-patch's
# update-checksums.sh records the new SHA256 in lib/checksums.json.

set -euo pipefail

# Source test framework
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "gitleaks version sync tests (#1050, #1064)"

DEV_TOOLS="$PROJECT_ROOT/lib/features/dev-tools.sh"
CI_WORKFLOW="$PROJECT_ROOT/.github/workflows/ci.yml"
CHECKSUMS="$PROJECT_ROOT/lib/checksums.json"

# First gitleaks release where both scoped allowlist forms in .gitleaks.toml
# (regexTarget value allowlist + targetRules path allowlist) take effect.
GITLEAKS_FLOOR="8.29.0"

# _dev_tools_version <file>
# Prints the X.Y.Z default from `GITLEAKS_VERSION="${GITLEAKS_VERSION:-X.Y.Z}"`.
_dev_tools_version() {
    command grep -E '^GITLEAKS_VERSION=' "$1" |
        command sed -E 's/.*:-([^}]*)}.*/\1/'
}

# _install_step <file>
# Prints the body of ci.yml's "Install gitleaks" step, up to the next step.
_install_step() {
    command awk '
        /- name: Install gitleaks/ { inside = 1; print; next }
        inside && /^[[:space:]]*- name:/ { exit }
        inside { print }
    ' "$1"
}

DEV_VERSION="$(_dev_tools_version "$DEV_TOOLS")"

test_source_of_truth_parses() {
    assert_matches "$DEV_VERSION" '^[0-9]+\.[0-9]+\.[0-9]+$' \
        "dev-tools.sh GITLEAKS_VERSION default must be X.Y.Z (got '$DEV_VERSION')"
}

test_dev_tools_version_meets_floor() {
    local lowest
    lowest="$(printf '%s\n%s\n' "$GITLEAKS_FLOOR" "$DEV_VERSION" | command sort -V | command head -n 1)"
    assert_equals "$GITLEAKS_FLOOR" "$lowest" \
        "dev-tools.sh GITLEAKS_VERSION ($DEV_VERSION) must be >= $GITLEAKS_FLOOR, or .gitleaks.toml's scoped allowlists are ignored"
}

# Without a recorded checksum the CI install step hard-fails, so catch it here
# with a clearer message.
test_checksum_recorded_for_pinned_version() {
    local sha
    sha="$(command jq -r --arg v "$DEV_VERSION" \
        '.tools.gitleaks.versions[$v].checksums.amd64.sha256 // empty' "$CHECKSUMS")"
    assert_matches "$sha" '^[0-9a-f]{64}$' \
        "lib/checksums.json must record an amd64 sha256 for gitleaks $DEV_VERSION"
}

# The action downloads unverified; it must not come back.
test_ci_does_not_use_gitleaks_action() {
    local hits
    hits="$(command grep -cE '^[[:space:]]*uses:[[:space:]]*gitleaks/gitleaks-action' "$CI_WORKFLOW" || true)"
    assert_equals "0" "$hits" \
        "ci.yml must not run gitleaks/gitleaks-action (unverified download, #1064)"
}

# A version literal in ci.yml would drift from dev-tools.sh and turn every
# gitleaks bump into a workflow-file push.
test_ci_has_no_version_literal() {
    local hits
    hits="$(command grep -cE 'GITLEAKS_VERSION[:=][[:space:]]*"?[0-9]' "$CI_WORKFLOW" || true)"
    assert_equals "0" "$hits" \
        "ci.yml must read GITLEAKS_VERSION from dev-tools.sh, not pin its own"
}

test_ci_install_reads_dev_tools_and_verifies() {
    local step
    step="$(_install_step "$CI_WORKFLOW")"
    assert_not_empty "$step" "ci.yml must have an 'Install gitleaks' step"
    assert_contains "$step" "lib/features/dev-tools.sh" \
        "the install step must read the version from dev-tools.sh"
    assert_contains "$step" ".tools.gitleaks.versions" \
        "the install step must look the checksum up in lib/checksums.json"
    assert_contains "$step" "sha256sum -c" \
        "the install step must verify the download with sha256sum -c"
}

# The scan must use the verified binary, i.e. come after the install step.
test_ci_scan_follows_install() {
    local install_line scan_line
    install_line="$(command grep -n -- '- name: Install gitleaks' "$CI_WORKFLOW" | command head -n 1 | command cut -d: -f1)"
    scan_line="$(command grep -n 'gitleaks git ' "$CI_WORKFLOW" | command head -n 1 | command cut -d: -f1)"
    assert_not_empty "$install_line" "ci.yml must install gitleaks"
    assert_not_empty "$scan_line" "ci.yml must run 'gitleaks git'"
    assert_true "[ ${install_line:-0} -lt ${scan_line:-0} ]" \
        "the gitleaks scan must run after the checksum-verified install"
}

# _run_updater <root> — run the real gitleaks updater case against a scratch
# PROJECT_ROOT (bump to 99.1.2). Prints the return code.
_run_updater() {
    local rc=0
    (
        source "$PROJECT_ROOT/bin/lib/common.sh"
        source "$PROJECT_ROOT/bin/lib/version-utils.sh"
        source "$PROJECT_ROOT/bin/lib/update-versions/updaters.sh"
        PROJECT_ROOT="$1"
        # shellcheck disable=SC2034 # consumed by update_version()
        DRY_RUN=false
        update_version "gitleaks" "$DEV_VERSION" "99.1.2" "dev-tools.sh"
    ) >/dev/null 2>&1 || rc=$?
    printf '%s\n' "$rc"
}

# A gitleaks bump moves the dev-tools.sh pin and never touches a workflow file.
test_updater_bumps_dev_tools_only() {
    local root="$TEST_SCRATCH_BASE/gitleaks-sync-ok" rc dev_after ci_same=yes
    /bin/mkdir -p "$root/lib/features" "$root/.github/workflows"
    /bin/cp "$DEV_TOOLS" "$root/lib/features/dev-tools.sh"
    /bin/cp "$CI_WORKFLOW" "$root/.github/workflows/ci.yml"
    rc="$(_run_updater "$root")"
    dev_after="$(_dev_tools_version "$root/lib/features/dev-tools.sh")"
    command cmp -s "$CI_WORKFLOW" "$root/.github/workflows/ci.yml" || ci_same=no
    /bin/rm -rf "$root"

    assert_equals "0" "$rc" "update_version gitleaks must succeed"
    assert_equals "99.1.2" "$dev_after" "updater must bump dev-tools.sh GITLEAKS_VERSION"
    assert_equals "yes" "$ci_same" "a gitleaks bump must leave ci.yml byte-identical"
}

# sed_inplace must return sed's own status. Its cleanup loop used to run last,
# so a failed sed reported 0 and every `sed_inplace ... || return` guard in
# rust-pins.sh was dead code.
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

run_test test_source_of_truth_parses "dev-tools.sh GITLEAKS_VERSION default parses"
run_test test_dev_tools_version_meets_floor "dev-tools.sh GITLEAKS_VERSION is >= $GITLEAKS_FLOOR"
run_test test_checksum_recorded_for_pinned_version "lib/checksums.json records the pinned version's sha256"
run_test test_ci_does_not_use_gitleaks_action "ci.yml does not use gitleaks-action"
run_test test_ci_has_no_version_literal "ci.yml carries no gitleaks version literal"
run_test test_ci_install_reads_dev_tools_and_verifies "ci.yml install step reads dev-tools.sh and verifies sha256"
run_test test_ci_scan_follows_install "ci.yml scan runs after the verified install"
run_test test_updater_bumps_dev_tools_only "updater bumps dev-tools.sh and leaves ci.yml alone"
run_test test_sed_inplace_propagates_sed_failure "sed_inplace returns sed's failure status"

generate_report
