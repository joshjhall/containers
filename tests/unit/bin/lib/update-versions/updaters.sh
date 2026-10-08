#!/usr/bin/env bash
# Unit tests for bin/lib/update-versions/updaters.sh failure reporting (#1063)
#
# update_version() returns the status of its arm's last statement. Before every
# write was guarded, a failed early write followed by a successful later one
# returned 0, so a half-updated tree was reported as a clean bump. And a pin
# line its case could not rewrite was reported as an "invalid version string",
# sending the operator after a bad upstream release that did not exist.

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Bin Lib Update Versions Updaters Tests"

UPDATERS="$PROJECT_ROOT/bin/lib/update-versions/updaters.sh"

# Return codes, read from the source so these tests cannot drift from them.
_rc() {
    command sed -nE "s/^$1=([0-9]+).*/\\1/p" "$UPDATERS"
}
RC_INVALID_VERSION="$(_rc RC_INVALID_VERSION)"
RC_UPDATE_FAILED="$(_rc RC_UPDATE_FAILED)"
RC_PIN_UNREWRITABLE="$(_rc RC_PIN_UNREWRITABLE)"

# ============================================================================
# Test: every write in update_version() is guarded
# ============================================================================
# Structural guard so a newly added arm cannot reintroduce the masked failure:
# every write update_version() makes — a sed_inplace or one of the writing
# helpers — must end in `|| return`. A bare `|| return` passes the helper's own
# code through (bump_gitleaks_pin distinguishes refusal from write failure).
test_every_write_is_guarded() {
    local writer='^[[:space:]]+(sed_inplace|pin_action|update_luggage_catalog|sync_[a-z_]+|bump_[a-z_]+) '
    local unguarded seds helpers
    unguarded="$(command awk -v w="$writer" '
        /^update_version\(\)/ { inside = 1 }
        inside && /^}/ { inside = 0 }
        inside && $0 ~ w && !/\|\| return( "\$RC_UPDATE_FAILED")?$/ {
            print FILENAME ":" NR
        }
    ' "$UPDATERS")"
    # Guard against either half of the scan silently matching nothing (e.g. a
    # renamed or re-indented call), which would pass with nothing checked.
    seds="$(command awk -v w="$writer" '
        /^update_version\(\)/ { inside = 1 }
        inside && /^}/ { inside = 0 }
        inside && $0 ~ w && /^[[:space:]]+sed_inplace / { n++ }
        END { print n + 0 }
    ' "$UPDATERS")"
    helpers="$(command awk -v w="$writer" '
        /^update_version\(\)/ { inside = 1 }
        inside && /^}/ { inside = 0 }
        inside && $0 ~ w && !/^[[:space:]]+sed_inplace / { n++ }
        END { print n + 0 }
    ' "$UPDATERS")"

    assert_not_equals "0" "$seds" "the guard scan must find update_version()'s sed_inplace writes"
    assert_not_equals "0" "$helpers" "the guard scan must find update_version()'s writer-helper calls"
    assert_equals "" "$unguarded" \
        "every write in update_version() must end in || return"
}

# ============================================================================
# Test: a failed non-final write is reported (RC_UPDATE_FAILED / exit 3)
# ============================================================================
# The Python arm writes the Dockerfile, then python.sh. With no Dockerfile the
# first write fails and the second succeeds — the exact half-update that used
# to return 0.
_write_partial_fixture() {
    local root="$1"
    /bin/mkdir -p "$root/lib/features"
    command cat >"$root/lib/features/python.sh" <<'EOF'
#!/bin/bash
PYTHON_VERSION="${PYTHON_VERSION:-3.12.7}"
EOF
    command cat >"$root/test.json" <<'EOF'
{
  "tools": [
    {"tool": "Python", "current": "3.12.7", "latest": "3.12.8", "file": "Dockerfile", "status": "outdated"}
  ]
}
EOF
}

test_failed_non_final_write_returns_update_failed() {
    local root="$TEST_SCRATCH_BASE/updaters-partial" rc=0
    _write_partial_fixture "$root"

    (
        source "$PROJECT_ROOT/bin/lib/common.sh"
        source "$PROJECT_ROOT/bin/lib/version-utils.sh"
        source "$UPDATERS"
        # shellcheck disable=SC2030,SC2034 # consumed by update_version()
        PROJECT_ROOT="$root"
        # shellcheck disable=SC2030,SC2034 # ditto
        DRY_RUN=false
        update_version "Python" "3.12.7" "3.12.8" "Dockerfile"
    ) >/dev/null 2>&1 || rc=$?
    /bin/rm -rf "$root"

    assert_equals "$RC_UPDATE_FAILED" "$rc" \
        "a failed Dockerfile write must return RC_UPDATE_FAILED even though python.sh's write succeeds"
}

test_failed_non_final_write_exits_three() {
    local root="$TEST_SCRATCH_BASE/updaters-partial-script" rc=0
    _write_partial_fixture "$root"

    (
        cd "$root" || exit 1
        # shellcheck disable=SC2031 # separate subshell
        PROJECT_ROOT_OVERRIDE="$root" "$PROJECT_ROOT/bin/update-versions.sh" \
            --no-commit --no-bump --input test.json
    ) >/dev/null 2>&1 || rc=$?
    /bin/rm -rf "$root"

    assert_equals "3" "$rc" "a half-updated arm must be fatal (exit 3), not reported as success"
}

# ============================================================================
# Test: a pin-shape refusal is held (exit 2) under its own summary label
# ============================================================================
test_pin_refusal_reported_as_unrewritable_pin() {
    local root="$TEST_SCRATCH_BASE/updaters-pin-shape" rc=0 output
    /bin/mkdir -p "$root/lib/features"
    # Unquoted: not a shape bump_gitleaks_pin's seds can rewrite.
    command cat >"$root/lib/features/dev-tools.sh" <<'EOF'
#!/bin/bash
GITLEAKS_VERSION=8.30.1
EOF
    command cat >"$root/test.json" <<'EOF'
{
  "tools": [
    {"tool": "gitleaks", "current": "8.30.1", "latest": "8.31.0", "file": "dev-tools.sh", "status": "outdated"}
  ]
}
EOF

    output="$(
        cd "$root" || exit 1
        # shellcheck disable=SC2031 # separate subshell
        PROJECT_ROOT_OVERRIDE="$root" "$PROJECT_ROOT/bin/update-versions.sh" \
            --no-commit --no-bump --input test.json 2>&1
    )" || rc=$?
    /bin/rm -rf "$root"

    assert_equals "2" "$rc" "a pin-shape refusal must hold the tool (exit 2)"
    assert_contains "$output" "pin line not in the shape" \
        "the summary must name the pin-shape cause"
    assert_not_contains "$output" "invalid version strings" \
        "a pin-shape refusal must not be reported as an invalid version"
}

# ============================================================================
# Test: a write failure outranks a pin-shape hold in the same run
# ============================================================================
# Exit 3 (tree may be half-updated) must win over exit 2 (tools held), and both
# causes must still be summarized — a held tool must not hide a fatal one.
test_mixed_failures_exit_three_and_report_both() {
    local root="$TEST_SCRATCH_BASE/updaters-mixed" rc=0 output
    _write_partial_fixture "$root"
    command cat >"$root/lib/features/dev-tools.sh" <<'EOF'
#!/bin/bash
GITLEAKS_VERSION=8.30.1
EOF
    command cat >"$root/test.json" <<'EOF'
{
  "tools": [
    {"tool": "gitleaks", "current": "8.30.1", "latest": "8.31.0", "file": "dev-tools.sh", "status": "outdated"},
    {"tool": "Python", "current": "3.12.7", "latest": "3.12.8", "file": "Dockerfile", "status": "outdated"}
  ]
}
EOF

    output="$(
        cd "$root" || exit 1
        # shellcheck disable=SC2031 # separate subshell
        PROJECT_ROOT_OVERRIDE="$root" "$PROJECT_ROOT/bin/update-versions.sh" \
            --no-commit --no-bump --input test.json 2>&1
    )" || rc=$?
    /bin/rm -rf "$root"

    assert_equals "3" "$rc" "a write failure must make the run fatal even alongside a held tool"
    assert_contains "$output" "pin line not in the shape" "the held tool must still be summarized"
    assert_contains "$output" "rewrite error" "the failed tool must be summarized"
}

# ============================================================================
# Test: the return codes stay distinct
# ============================================================================
test_return_codes_distinct() {
    assert_not_equals "$RC_INVALID_VERSION" "$RC_PIN_UNREWRITABLE" \
        "RC_PIN_UNREWRITABLE must be distinct from RC_INVALID_VERSION"
    assert_not_equals "$RC_UPDATE_FAILED" "$RC_PIN_UNREWRITABLE" \
        "RC_PIN_UNREWRITABLE must be distinct from RC_UPDATE_FAILED"
}

run_test test_every_write_is_guarded "Every write in update_version() is guarded"
run_test test_failed_non_final_write_returns_update_failed "Failed non-final write returns RC_UPDATE_FAILED"
run_test test_failed_non_final_write_exits_three "Failed non-final write exits 3"
run_test test_pin_refusal_reported_as_unrewritable_pin "Pin-shape refusal is held under its own label"
run_test test_mixed_failures_exit_three_and_report_both "Write failure outranks a pin-shape hold"
run_test test_return_codes_distinct "Return codes are distinct"

# Generate test report
generate_report
