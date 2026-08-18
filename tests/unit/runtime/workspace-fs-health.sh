#!/usr/bin/env bash
# Unit tests for lib/runtime/42-workspace-fs-health.sh
# Tests core.ignorecase alignment and stale-symlink repair

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Workspace Filesystem Health Tests"

# Path to the script under test
FS_HEALTH_SCRIPT="$(dirname "${BASH_SOURCE[0]}")/../../../lib/runtime/42-workspace-fs-health.sh"
FS_HEALTH_SCRIPT="$(cd "$(dirname "$FS_HEALTH_SCRIPT")" && pwd)/$(basename "$FS_HEALTH_SCRIPT")"

# ============================================================================
# Test Setup / Teardown
# ============================================================================

setup() {
    export TEST_TEMP_DIR="$RESULTS_DIR/test-workspace-fs-health-$$"
    command mkdir -p "$TEST_TEMP_DIR"

    export PROJECT_ROOT="$TEST_TEMP_DIR/project"
    command mkdir -p "$PROJECT_ROOT"

    # A real repo — the script reads and writes git config and the index.
    # Identity must be set explicitly; the committing tests fail otherwise on
    # a host with no global git identity.
    git -C "$PROJECT_ROOT" init -q .
    git -C "$PROJECT_ROOT" config user.email "test@example.com"
    git -C "$PROJECT_ROOT" config user.name "Test User"

    # git init auto-detects the host filesystem, which would pre-set
    # core.ignorecase on a case-insensitive host and mask the very behavior
    # under test. Start from a known-unset state.
    git -C "$PROJECT_ROOT" config --unset core.ignorecase 2>/dev/null || true

    unset SKIP_CASE_CHECK SKIP_CASE_FIX 2>/dev/null || true
}

teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
    unset PROJECT_ROOT TEST_TEMP_DIR SKIP_CASE_CHECK SKIP_CASE_FIX 2>/dev/null || true
}

# Run the script with the filesystem verdict forced via FS_CASE_STATE, so the
# suite behaves identically on case-sensitive and case-insensitive hosts.
# Args: $1=fs state (sensitive|insensitive|unknown)
run_fs_health() {
    (
        export PROJECT_ROOT
        export FS_CASE_STATE="$1"
        export SKIP_CASE_CHECK="${SKIP_CASE_CHECK:-false}"
        export SKIP_CASE_FIX="${SKIP_CASE_FIX:-false}"
        bash "$FS_HEALTH_SCRIPT"
    ) 2>/dev/null
}

# Same, but return only stderr (where all reporting goes), discarding stdout.
run_fs_health_stderr() {
    (
        export PROJECT_ROOT
        export FS_CASE_STATE="$1"
        export SKIP_CASE_CHECK="${SKIP_CASE_CHECK:-false}"
        export SKIP_CASE_FIX="${SKIP_CASE_FIX:-false}"
        { bash "$FS_HEALTH_SCRIPT" >/dev/null; } 2>&1
    )
}

# Current core.ignorecase, or the literal "unset"
get_ignorecase() {
    git -C "$PROJECT_ROOT" config --get core.ignorecase 2>/dev/null || echo "unset"
}

# ============================================================================
# Skip Condition Tests
# ============================================================================

test_skip_when_case_check_disabled() {
    export SKIP_CASE_CHECK=true
    run_fs_health insensitive
    assert_equals "unset" "$(get_ignorecase)" \
        "Should not touch core.ignorecase when SKIP_CASE_CHECK=true"
}

test_skip_when_not_a_git_repo() {
    command rm -rf "$PROJECT_ROOT/.git"
    run_fs_health insensitive
    assert_dir_not_exists "$PROJECT_ROOT/.git" \
        "Should exit cleanly without creating anything in a non-git dir"
}

test_worktree_git_file_accepted() {
    # A linked worktree's .git is a file, not a directory. The guard must
    # accept both shapes or worktrees silently skip the repair.
    local real_git="$PROJECT_ROOT/.git"
    command mv "$real_git" "$TEST_TEMP_DIR/realgit"
    echo "gitdir: $TEST_TEMP_DIR/realgit" >"$real_git"

    run_fs_health insensitive

    local result
    result=$(git --git-dir="$TEST_TEMP_DIR/realgit" config --get core.ignorecase 2>/dev/null || echo "unset")
    assert_equals "true" "$result" \
        "Should repair a worktree whose .git is a file"
}

# ============================================================================
# core.ignorecase Tests
# ============================================================================

test_sets_ignorecase_when_insensitive() {
    run_fs_health insensitive
    assert_equals "true" "$(get_ignorecase)" \
        "Should set core.ignorecase=true on a case-insensitive filesystem"
}

test_leaves_ignorecase_when_sensitive() {
    run_fs_health sensitive
    assert_equals "unset" "$(get_ignorecase)" \
        "Should not set core.ignorecase on a case-sensitive filesystem"
}

test_no_change_when_detection_unknown() {
    # Exit code 2 from the detector means "could not determine" — that is not
    # evidence of case-insensitivity and must never trigger a write.
    run_fs_health unknown
    assert_equals "unset" "$(get_ignorecase)" \
        "Should not set core.ignorecase when detection is inconclusive"
}

test_corrects_explicit_false() {
    git -C "$PROJECT_ROOT" config core.ignorecase false
    run_fs_health insensitive
    assert_equals "true" "$(get_ignorecase)" \
        "Should correct an explicitly wrong core.ignorecase=false"
}

test_idempotent_when_already_true() {
    git -C "$PROJECT_ROOT" config core.ignorecase true
    local output
    output=$(run_fs_health_stderr insensitive)
    assert_equals "true" "$(get_ignorecase)" \
        "Should leave an already-correct core.ignorecase alone"
    assert_empty "$output" \
        "Should print nothing when core.ignorecase is already correct"
}

test_skip_fix_reports_without_writing() {
    export SKIP_CASE_FIX=true
    local output
    output=$(run_fs_health_stderr insensitive)
    assert_equals "unset" "$(get_ignorecase)" \
        "SKIP_CASE_FIX=true should not write core.ignorecase"
    assert_contains "$output" "case-insensitive" \
        "SKIP_CASE_FIX=true should still report the problem"
}

# ============================================================================
# Reporting Tests
# ============================================================================

test_silent_when_healthy() {
    local output
    output=$(run_fs_health_stderr sensitive)
    assert_empty "$output" \
        "Should print nothing on a healthy case-sensitive filesystem"
}

test_reports_when_repairing() {
    local output
    output=$(run_fs_health_stderr insensitive)
    assert_contains "$output" "core.ignorecase" \
        "Should name the setting it changed"
}

# ============================================================================
# Symlink Repair Tests
# ============================================================================
# A stale symlink reports the impossible nlink=0. That state cannot be created
# on demand (it is a filesystem cache artifact), so these tests verify the
# guard's *inaction* on every symlink shape that must be left alone, which is
# where the data-loss risk lives.

# Create tracked symlinks of each shape in the fixture repo.
seed_symlinks() {
    echo "content" >"$PROJECT_ROOT/realfile.txt"
    command mkdir -p "$PROJECT_ROOT/subdir"
    echo "inner" >"$PROJECT_ROOT/subdir/inner.txt"
    command ln -s realfile.txt "$PROJECT_ROOT/good.link"
    command ln -s /nonexistent/target "$PROJECT_ROOT/broken.link"
    command ln -s subdir "$PROJECT_ROOT/dir.link"
    git -C "$PROJECT_ROOT" add -A >/dev/null 2>&1
    git -C "$PROJECT_ROOT" commit -qm "seed symlinks" >/dev/null 2>&1
}

test_healthy_symlink_untouched() {
    seed_symlinks
    run_fs_health sensitive
    assert_equals "realfile.txt" "$(command readlink "$PROJECT_ROOT/good.link")" \
        "Healthy symlink target should be unchanged"
}

test_broken_symlink_untouched() {
    # A broken symlink still reports nlink=1, so it must not be mistaken for
    # a stale one and silently rewritten.
    seed_symlinks
    run_fs_health sensitive
    assert_equals "/nonexistent/target" "$(command readlink "$PROJECT_ROOT/broken.link")" \
        "Broken symlink should be left alone, not repaired"
}

test_directory_symlink_not_polluted() {
    # Relinking a directory symlink without `ln -n` would create the new link
    # *inside* the target directory. Guard against that regression.
    seed_symlinks
    run_fs_health sensitive
    assert_equals "subdir" "$(command readlink "$PROJECT_ROOT/dir.link")" \
        "Directory symlink target should be unchanged"
    assert_file_not_exists "$PROJECT_ROOT/subdir/subdir" \
        "Should not create a nested link inside the symlinked directory"
}

test_symlinks_leave_repo_clean() {
    seed_symlinks
    run_fs_health sensitive
    local status
    status=$(git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null)
    assert_empty "$status" \
        "Repo should remain clean after a no-op symlink pass"
}

test_silent_with_healthy_symlinks_present() {
    # The end state of a wrongly-triggered repair is indistinguishable from a
    # correct no-op (relinking to the same target is harmless), so the only
    # signal that the nlink=0 guard still works is that a repo full of healthy
    # symlinks produces no output at all.
    seed_symlinks
    local output
    output=$(run_fs_health_stderr sensitive)
    assert_empty "$output" \
        "Should not report repairs when every symlink is healthy"
}

test_regular_files_untouched() {
    # Only mode-120000 index entries are considered; regular files must never
    # be rewritten.
    seed_symlinks
    run_fs_health insensitive
    assert_equals "content" "$(command cat "$PROJECT_ROOT/realfile.txt")" \
        "Regular file contents should be untouched"
}

# ============================================================================
# Run all tests
# ============================================================================

run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"

    setup
    run_test "$test_function" "$test_description"
    teardown
}

run_test_with_setup test_skip_when_case_check_disabled "Skip when SKIP_CASE_CHECK=true"
run_test_with_setup test_skip_when_not_a_git_repo "Skip when not a git repository"
run_test_with_setup test_worktree_git_file_accepted "Accepts a worktree .git file"
run_test_with_setup test_sets_ignorecase_when_insensitive "Sets core.ignorecase on case-insensitive FS"
run_test_with_setup test_leaves_ignorecase_when_sensitive "Leaves core.ignorecase on case-sensitive FS"
run_test_with_setup test_no_change_when_detection_unknown "No change when detection is inconclusive"
run_test_with_setup test_corrects_explicit_false "Corrects an explicit core.ignorecase=false"
run_test_with_setup test_idempotent_when_already_true "Idempotent when core.ignorecase already true"
run_test_with_setup test_skip_fix_reports_without_writing "SKIP_CASE_FIX reports without writing"
run_test_with_setup test_silent_when_healthy "Silent when filesystem is healthy"
run_test_with_setup test_reports_when_repairing "Reports the setting it changed"
run_test_with_setup test_healthy_symlink_untouched "Healthy symlink left untouched"
run_test_with_setup test_broken_symlink_untouched "Broken symlink left untouched"
run_test_with_setup test_directory_symlink_not_polluted "Directory symlink not polluted"
run_test_with_setup test_symlinks_leave_repo_clean "Repo stays clean after symlink pass"
run_test_with_setup test_silent_with_healthy_symlinks_present "Silent when all symlinks are healthy"
run_test_with_setup test_regular_files_untouched "Regular files untouched"

# Generate test report
generate_report
