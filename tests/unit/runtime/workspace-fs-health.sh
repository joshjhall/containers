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

    # Redirect the cron env snapshot into the fixture. Without this the script
    # would write into the real $HOME/.cache/container/ on every test run.
    export FS_HEALTH_ENV_FILE="$TEST_TEMP_DIR/fs-health.env"

    unset SKIP_CASE_CHECK SKIP_CASE_FIX FS_HEALTH_UPDATE_ENV 2>/dev/null || true
}

teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
    unset PROJECT_ROOT TEST_TEMP_DIR SKIP_CASE_CHECK SKIP_CASE_FIX \
        FS_HEALTH_ENV_FILE FS_HEALTH_UPDATE_ENV 2>/dev/null || true
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
        export FS_HEALTH_ENV_FILE
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
        export FS_HEALTH_ENV_FILE
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
# Periodic Re-Run Tests (issue #794)
# ============================================================================
# The repair is time-driven, so it also runs hourly from cron. Cron inherits
# none of the container environment, so the boot run records PROJECT_ROOT and
# SKIP_CASE_FIX into an env snapshot; the snapshot's ABSENCE is what disables
# the cron leg. These tests cover that contract in both directions.

CRON_WRAPPER="$(dirname "${BASH_SOURCE[0]}")/../../../lib/runtime/workspace-fs-health-cron.sh"
CRON_WRAPPER="$(cd "$(dirname "$CRON_WRAPPER")" && pwd)/$(basename "$CRON_WRAPPER")"

ONDEMAND_WRAPPER="$(dirname "${BASH_SOURCE[0]}")/../../../lib/runtime/workspace-fs-health-run.sh"
ONDEMAND_WRAPPER="$(cd "$(dirname "$ONDEMAND_WRAPPER")" && pwd)/$(basename "$ONDEMAND_WRAPPER")"

# Run the cron wrapper with a clean environment — no PROJECT_ROOT, no
# SKIP_CASE_*, and a nonexistent cron-env — so it can only work from the
# snapshot, exactly as the real cron leg does. Returns stderr.
run_cron_wrapper() {
    (
        unset PROJECT_ROOT SKIP_CASE_CHECK SKIP_CASE_FIX 2>/dev/null || true
        export FS_HEALTH_SCRIPT="$FS_HEALTH_SCRIPT"
        export FS_HEALTH_ENV_FILE
        export CRON_ENV_FILE="$TEST_TEMP_DIR/no-such-cron-env"
        export FS_CASE_STATE="${1:-sensitive}"
        { bash "$CRON_WRAPPER" >/dev/null; } 2>&1
    )
}

get_snapshot_value() {
    /usr/bin/grep -E "^$1=" "$FS_HEALTH_ENV_FILE" 2>/dev/null | command sed "s/^$1=//; s/^'//; s/'$//"
}

test_writes_env_snapshot() {
    run_fs_health sensitive
    assert_file_exists "$FS_HEALTH_ENV_FILE" \
        "A normal run should record the env snapshot the cron leg needs"
    assert_equals "$PROJECT_ROOT" "$(get_snapshot_value PROJECT_ROOT)" \
        "Snapshot should carry the resolved PROJECT_ROOT"
    assert_equals "false" "$(get_snapshot_value SKIP_CASE_FIX)" \
        "Snapshot should record SKIP_CASE_FIX=false by default"
}

test_snapshot_records_skip_case_fix() {
    export SKIP_CASE_FIX=true
    run_fs_health sensitive
    assert_equals "true" "$(get_snapshot_value SKIP_CASE_FIX)" \
        "Snapshot should carry SKIP_CASE_FIX=true so cron inherits the opt-out"
}

test_skip_case_check_removes_snapshot() {
    # A snapshot from a boot BEFORE the opt-out was set would otherwise keep
    # the hourly leg repairing for a user who explicitly opted out.
    run_fs_health sensitive
    assert_file_exists "$FS_HEALTH_ENV_FILE" "Precondition: snapshot exists"

    export SKIP_CASE_CHECK=true
    run_fs_health sensitive
    assert_file_not_exists "$FS_HEALTH_ENV_FILE" \
        "SKIP_CASE_CHECK=true should remove a stale env snapshot"
}

test_non_repo_removes_snapshot() {
    run_fs_health sensitive
    assert_file_exists "$FS_HEALTH_ENV_FILE" "Precondition: snapshot exists"

    # Project unmounted / no longer a repo: the cron leg has nothing to repair
    # and must not be left pointing at it.
    command rm -rf "$PROJECT_ROOT/.git"
    run_fs_health sensitive
    assert_file_not_exists "$FS_HEALTH_ENV_FILE" \
        "A non-repo project root should clear the env snapshot"
}

test_cron_wrapper_noop_without_snapshot() {
    # No snapshot means "do not run" — never guess at PROJECT_ROOT, which under
    # cron would be the user's home directory.
    command rm -f "$FS_HEALTH_ENV_FILE"
    local output
    output=$(run_cron_wrapper insensitive)
    assert_empty "$output" \
        "Cron wrapper should be a silent no-op when no snapshot exists"
    assert_equals "unset" "$(get_ignorecase)" \
        "Cron wrapper should not repair anything without a snapshot"
}

test_cron_wrapper_repairs_from_snapshot() {
    # The whole point of #794: a repair that reaches the project on a later,
    # environment-less invocation rather than only at boot.
    run_fs_health sensitive
    assert_equals "unset" "$(get_ignorecase)" "Precondition: nothing repaired yet"

    run_cron_wrapper insensitive >/dev/null
    assert_equals "true" "$(get_ignorecase)" \
        "Cron wrapper should repair the project named by the snapshot"
}

test_cron_wrapper_honors_snapshot_skip_fix() {
    export SKIP_CASE_FIX=true
    run_fs_health sensitive
    unset SKIP_CASE_FIX

    local output
    output=$(run_cron_wrapper insensitive)
    assert_equals "unset" "$(get_ignorecase)" \
        "Cron wrapper should not write when the snapshot recorded SKIP_CASE_FIX=true"
    assert_contains "$output" "case-insensitive" \
        "Cron wrapper should still report the problem in report-only mode"
}

test_cron_wrapper_does_not_rewrite_snapshot() {
    # The snapshot belongs to the boot run. If the cron leg rewrote it from its
    # own environment, one bad cron invocation would permanently redirect every
    # later one.
    run_fs_health sensitive
    local before
    before=$(command cat "$FS_HEALTH_ENV_FILE")

    run_cron_wrapper insensitive >/dev/null
    assert_equals "$before" "$(command cat "$FS_HEALTH_ENV_FILE")" \
        "Cron wrapper should leave the boot run's snapshot unchanged"
}

test_ondemand_repairs_given_path() {
    # Resolve the target before the subshell clears PROJECT_ROOT — the point of
    # clearing it is to prove the path argument alone drives the repair.
    local target="$PROJECT_ROOT"
    local output
    output=$(
        cd "$TEST_TEMP_DIR" || exit 1
        export FS_HEALTH_SCRIPT="$FS_HEALTH_SCRIPT"
        export FS_HEALTH_ENV_FILE
        export FS_CASE_STATE=insensitive
        unset PROJECT_ROOT 2>/dev/null || true
        { bash "$ONDEMAND_WRAPPER" "$target" >/dev/null; } 2>&1
    )
    assert_equals "true" "$(get_ignorecase)" \
        "On-demand command should repair the project path it is given"
    assert_contains "$output" "core.ignorecase" \
        "On-demand command should report what it repaired"
}

test_ondemand_does_not_write_snapshot() {
    # An ad-hoc run from an arbitrary directory must not redirect the hourly
    # cron leg at whatever the user happened to cd into.
    command rm -f "$FS_HEALTH_ENV_FILE"
    (
        export FS_HEALTH_SCRIPT="$FS_HEALTH_SCRIPT"
        export FS_HEALTH_ENV_FILE
        export FS_CASE_STATE=insensitive
        bash "$ONDEMAND_WRAPPER" "$PROJECT_ROOT"
    ) >/dev/null 2>&1
    assert_file_not_exists "$FS_HEALTH_ENV_FILE" \
        "On-demand run should not create or overwrite the boot snapshot"
}

test_ondemand_rejects_bad_path() {
    local status=0
    (
        export FS_HEALTH_SCRIPT="$FS_HEALTH_SCRIPT"
        export FS_HEALTH_ENV_FILE
        bash "$ONDEMAND_WRAPPER" "$TEST_TEMP_DIR/does-not-exist"
    ) >/dev/null 2>&1 || status=$?
    assert_equals "1" "$status" \
        "On-demand command should fail loudly on a nonexistent path"
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
run_test_with_setup test_writes_env_snapshot "Writes the cron env snapshot"
run_test_with_setup test_snapshot_records_skip_case_fix "Snapshot records SKIP_CASE_FIX"
run_test_with_setup test_skip_case_check_removes_snapshot "SKIP_CASE_CHECK removes a stale snapshot"
run_test_with_setup test_non_repo_removes_snapshot "Non-repo project root clears the snapshot"
run_test_with_setup test_cron_wrapper_noop_without_snapshot "Cron wrapper no-ops without a snapshot"
run_test_with_setup test_cron_wrapper_repairs_from_snapshot "Cron wrapper repairs from the snapshot"
run_test_with_setup test_cron_wrapper_honors_snapshot_skip_fix "Cron wrapper honors snapshot SKIP_CASE_FIX"
run_test_with_setup test_cron_wrapper_does_not_rewrite_snapshot "Cron wrapper leaves the snapshot alone"
run_test_with_setup test_ondemand_repairs_given_path "On-demand command repairs a given path"
run_test_with_setup test_ondemand_does_not_write_snapshot "On-demand run does not write the snapshot"
run_test_with_setup test_ondemand_rejects_bad_path "On-demand command rejects a bad path"

# Generate test report
generate_report
