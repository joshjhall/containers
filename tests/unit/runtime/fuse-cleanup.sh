#!/usr/bin/env bash
# Unit tests for lib/runtime/fuse-cleanup.sh
#
# The shared .fuse_hidden* garbage collector (issue #948). These tests are
# deliberately BEHAVIORAL rather than assert_file_contains static analysis: the
# bug being regressed was a `-maxdepth 3` bound, and no static assertion can
# catch a depth that is too shallow. The fixture in test_removes_nested_file is
# the load-bearing one — per the issue, a top-level fixture PASSES against the
# broken code, so only a file four components deep actually fails without the
# fix.
#
# The script is driven through FUSE_CLEANUP_ROOTS so the tests need no real FUSE
# mount. That override takes precedence over findmnt discovery ON PURPOSE and
# the tests depend on it: this project's own dev container mounts its workspace
# via bindfs, so a test that relied on "findmnt finds nothing" would instead
# hand the script the live source tree to sweep.

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "FUSE Hidden File Cleanup Tests"

# Source file under test
SOURCE_FILE="$PROJECT_ROOT/lib/runtime/fuse-cleanup.sh"

setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$TEST_SCRATCH_BASE/test-fuse-cleanup-$unique_id"
    command mkdir -p "$TEST_TEMP_DIR"
}

teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
    unset TEST_TEMP_DIR FUSE_CLEANUP_DISABLE FUSE_CLEANUP_ROOTS \
        FUSE_CLEANUP_FALLBACK_ROOT 2>/dev/null || true
}

run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"
    setup
    run_test "$test_function" "$test_description"
    teardown
}

# Run the GC against a scratch root, echoing its stdout (the cleaned count).
run_cleanup() {
    local root="$1"
    FUSE_CLEANUP_ROOTS="$root" bash "$SOURCE_FILE"
}

# ============================================================================
# Static Analysis Tests
# ============================================================================

test_script_exists() {
    assert_file_exists "$SOURCE_FILE" "fuse-cleanup.sh exists"
}

test_syntax_valid() {
    if bash -n "$SOURCE_FILE" 2>&1; then
        pass_test "Script has valid bash syntax"
    else
        fail_test "Script has syntax errors"
    fi
}

test_no_maxdepth_bound() {
    # The entire point of #948: a depth bound is a guess about someone else's
    # directory layout. If one is ever reintroduced, this fails loudly next to
    # the behavioral tests that would also fail.
    #
    # Matches the find flag, not the bare word — the header comment explains the
    # bug being regressed and necessarily names -maxdepth.
    if command grep -qE '^[^#]*-maxdepth' "$SOURCE_FILE"; then
        fail_test "Walk is depth-bounded — -maxdepth reintroduced (issue #948)"
    else
        pass_test "Walk is not depth-bounded (issue #948)"
    fi
}

test_uses_findmnt_for_roots() {
    assert_file_contains "$SOURCE_FILE" "findmnt" \
        "Discovers roots via findmnt so both callers agree on the root"
}

test_checks_fuser() {
    assert_file_contains "$SOURCE_FILE" "fuser" \
        "Checks fuser before removing a hidden file"
}

test_honors_disable_gate() {
    assert_file_contains "$SOURCE_FILE" "FUSE_CLEANUP_DISABLE" \
        "Honors FUSE_CLEANUP_DISABLE"
}

# ============================================================================
# Behavioral Tests
# ============================================================================

test_removes_nested_file() {
    # THE regression test for #948. Four components below the root — the depth
    # at which plugins/<plugin>/scripts/.fuse_hiddenXXXX sits, and the depth the
    # old `-maxdepth 3` could not reach.
    command mkdir -p "$TEST_TEMP_DIR/a/b/c/d"
    local nested="$TEST_TEMP_DIR/a/b/c/d/.fuse_hiddenDEAD"
    : >"$nested"

    run_cleanup "$TEST_TEMP_DIR" >/dev/null

    assert_file_not_exists "$nested" \
        "Removes .fuse_hidden file nested 4 levels deep (issue #948)"
}

test_removes_deeply_nested_file() {
    # Well past any plausible depth bound — proves the walk is unbounded rather
    # than merely bounded at a larger number.
    command mkdir -p "$TEST_TEMP_DIR/l1/l2/l3/l4/l5/l6/l7/l8"
    local deep="$TEST_TEMP_DIR/l1/l2/l3/l4/l5/l6/l7/l8/.fuse_hiddenFEED"
    : >"$deep"

    run_cleanup "$TEST_TEMP_DIR" >/dev/null

    assert_file_not_exists "$deep" \
        "Removes .fuse_hidden file nested 8 levels deep"
}

test_removes_top_level_file() {
    # The flat case worked before the fix; make sure it still does.
    local flat="$TEST_TEMP_DIR/.fuse_hiddenBEEF"
    : >"$flat"

    run_cleanup "$TEST_TEMP_DIR" >/dev/null

    assert_file_not_exists "$flat" \
        "Removes top-level .fuse_hidden file (no regression on flat repos)"
}

test_prunes_git_directory() {
    # .git is pruned for cost, not correctness — but a prune that accidentally
    # swept it would be a nasty surprise, so pin the behavior.
    command mkdir -p "$TEST_TEMP_DIR/.git/objects"
    local in_git="$TEST_TEMP_DIR/.git/objects/.fuse_hiddenGIT1"
    : >"$in_git"

    run_cleanup "$TEST_TEMP_DIR" >/dev/null

    assert_file_exists "$in_git" \
        "Does not descend into .git (pruned)"
}

test_prunes_node_modules() {
    command mkdir -p "$TEST_TEMP_DIR/node_modules/pkg"
    local in_nm="$TEST_TEMP_DIR/node_modules/pkg/.fuse_hiddenNM01"
    : >"$in_nm"

    run_cleanup "$TEST_TEMP_DIR" >/dev/null

    assert_file_exists "$in_nm" \
        "Does not descend into node_modules (pruned)"
}

test_leaves_unrelated_files() {
    command mkdir -p "$TEST_TEMP_DIR/src/deep"
    local keep="$TEST_TEMP_DIR/src/deep/regular.txt"
    : >"$keep"

    run_cleanup "$TEST_TEMP_DIR" >/dev/null

    assert_file_exists "$keep" \
        "Leaves non-.fuse_hidden files untouched"
}

test_reports_cleaned_count() {
    command mkdir -p "$TEST_TEMP_DIR/x/y/z"
    : >"$TEST_TEMP_DIR/.fuse_hidden0001"
    : >"$TEST_TEMP_DIR/x/.fuse_hidden0002"
    : >"$TEST_TEMP_DIR/x/y/z/.fuse_hidden0003"

    local count
    count=$(run_cleanup "$TEST_TEMP_DIR")

    assert_equals "3" "$count" \
        "Reports the number of files removed on stdout"
}

test_reports_zero_when_clean() {
    command mkdir -p "$TEST_TEMP_DIR/empty"

    local count
    count=$(run_cleanup "$TEST_TEMP_DIR")

    assert_equals "0" "$count" \
        "Reports 0 when there is nothing to clean"
}

test_disable_gate_removes_nothing() {
    local flat="$TEST_TEMP_DIR/.fuse_hiddenSKIP"
    : >"$flat"

    local rc=0
    FUSE_CLEANUP_DISABLE=true FUSE_CLEANUP_ROOTS="$TEST_TEMP_DIR" \
        bash "$SOURCE_FILE" >/dev/null || rc=$?

    assert_equals "0" "$rc" "Exits 0 when disabled"
    assert_file_exists "$flat" \
        "FUSE_CLEANUP_DISABLE=true removes nothing"
}

# Build a findmnt stub that reports no FUSE mounts, so the fallback path can be
# exercised for real. Needed because this project's own dev container mounts its
# workspace via bindfs — the genuine findmnt returns that live tree.
#
# The stub is injected via FUSE_CLEANUP_FINDMNT rather than by prepending to
# PATH: the container's BASH_ENV rc files re-export PATH, so a prepended stub
# dir is silently dropped before the script under test ever runs.
# Echoes the stub's path.
stub_findmnt() {
    local stub_dir="$TEST_TEMP_DIR/stub-bin"
    command mkdir -p "$stub_dir"
    command printf '%s\n' '#!/bin/bash' 'exit 0' >"$stub_dir/findmnt"
    command chmod +x "$stub_dir/findmnt"
    echo "$stub_dir/findmnt"
}

test_fallback_root_is_used() {
    # The boot pass's path: no FUSE mounts, so the fallback root is swept —
    # and swept to full depth, like everything else.
    local sweep_root="$TEST_TEMP_DIR/workspace"
    command mkdir -p "$sweep_root/deep/er/still"
    local nested="$sweep_root/deep/er/still/.fuse_hiddenFB01"
    : >"$nested"

    local stub
    stub=$(stub_findmnt)

    FUSE_CLEANUP_FINDMNT="$stub" FUSE_CLEANUP_FALLBACK_ROOT="$sweep_root" \
        bash "$SOURCE_FILE" >/dev/null

    assert_file_not_exists "$nested" \
        "Sweeps FUSE_CLEANUP_FALLBACK_ROOT when no FUSE mount is found"
}

test_missing_root_exits_clean() {
    # A fallback root that does not exist must not error.
    local stub
    stub=$(stub_findmnt)

    local rc=0
    FUSE_CLEANUP_FINDMNT="$stub" FUSE_CLEANUP_FALLBACK_ROOT="$TEST_TEMP_DIR/does-not-exist" \
        bash "$SOURCE_FILE" >/dev/null || rc=$?

    assert_equals "0" "$rc" "Exits 0 when the fallback root does not exist"
}

test_no_root_configured_exits_clean() {
    local stub
    stub=$(stub_findmnt)

    local rc=0
    local out
    out=$(FUSE_CLEANUP_FINDMNT="$stub" bash "$SOURCE_FILE" 2>/dev/null) || rc=$?

    assert_equals "0" "$rc" "Exits 0 with no root configured"
    assert_equals "0" "$out" "Reports 0 with no root to sweep"
}

test_idempotent() {
    command mkdir -p "$TEST_TEMP_DIR/a/b/c/d"
    : >"$TEST_TEMP_DIR/a/b/c/d/.fuse_hiddenTWICE"

    run_cleanup "$TEST_TEMP_DIR" >/dev/null

    local second
    second=$(run_cleanup "$TEST_TEMP_DIR")

    assert_equals "0" "$second" \
        "Second run is a clean no-op (idempotent)"
}

test_handles_spaces_in_path() {
    # The walk is -print0/read -d '' end to end; a path with a space must
    # survive it.
    command mkdir -p "$TEST_TEMP_DIR/dir with space/nested"
    local spaced="$TEST_TEMP_DIR/dir with space/nested/.fuse_hiddenSPACE"
    : >"$spaced"

    run_cleanup "$TEST_TEMP_DIR" >/dev/null

    assert_file_not_exists "$spaced" \
        "Removes a .fuse_hidden file under a path containing spaces"
}

# ============================================================================
# Run all tests
# ============================================================================

# Static analysis
run_test test_script_exists "Script exists"
run_test test_syntax_valid "Script has valid bash syntax"
run_test test_no_maxdepth_bound "Walk is not depth-bounded"
run_test test_uses_findmnt_for_roots "Discovers roots via findmnt"
run_test test_checks_fuser "Checks fuser before removal"
run_test test_honors_disable_gate "Honors FUSE_CLEANUP_DISABLE"

# Behavioral tests
run_test_with_setup test_removes_nested_file "Removes file nested 4 deep (#948)"
run_test_with_setup test_removes_deeply_nested_file "Removes file nested 8 deep"
run_test_with_setup test_removes_top_level_file "Removes top-level file"
run_test_with_setup test_prunes_git_directory "Prunes .git"
run_test_with_setup test_prunes_node_modules "Prunes node_modules"
run_test_with_setup test_leaves_unrelated_files "Leaves unrelated files"
run_test_with_setup test_reports_cleaned_count "Reports cleaned count"
run_test_with_setup test_reports_zero_when_clean "Reports 0 when clean"
run_test_with_setup test_disable_gate_removes_nothing "Disable gate removes nothing"
run_test_with_setup test_fallback_root_is_used "Fallback root is swept"
run_test_with_setup test_missing_root_exits_clean "Missing root exits clean"
run_test_with_setup test_no_root_configured_exits_clean "No root configured exits clean"
run_test_with_setup test_idempotent "Idempotent"
run_test_with_setup test_handles_spaces_in_path "Handles spaces in paths"

# Generate test report
generate_report
