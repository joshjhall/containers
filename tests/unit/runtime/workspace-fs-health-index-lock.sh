#!/usr/bin/env bash
# Unit tests for lib/runtime/42-workspace-fs-health.sh — the stale git
# index.lock diagnostic (issue #1086).
#
# Sibling-file shape follows workspace-fs-health-xattr.sh: self-contained,
# driven through the shared helper's fixtures. The misreported virtiofs rename
# that strands the lock cannot be produced on demand, but its RESIDUE can — a
# plain file at <git-dir>/index.lock with an old mtime — and that residue is the
# only thing the diagnostic looks at.

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Workspace FS Health Stale index.lock Tests"

# Shared fixtures: FS_HEALTH_SCRIPT, setup/teardown, run_fs_health_stderr,
# run_test_with_setup. Sourced after init_test_framework — setup() reads
# TEST_SCRATCH_BASE.
source "$(dirname "${BASH_SOURCE[0]}")/../../framework/helpers/workspace-fs-health.sh"

# Commit one file so the repo has a real index to sit next to the lock.
seed_commit() {
    echo "content" >"$PROJECT_ROOT/file.txt"
    git -C "$PROJECT_ROOT" add -A >/dev/null 2>&1
    git -C "$PROJECT_ROOT" commit -qm "seed" >/dev/null 2>&1
}

# Plant a lock at $1 whose mtime is an hour old — well past the 600s cutoff.
plant_stale_lock() {
    echo "phantom" >"$1"
    command touch -d '1 hour ago' "$1"
}

# ============================================================================
# Stale index.lock diagnostic (issue #1086)
# ============================================================================

test_stale_lock_is_reported() {
    seed_commit
    plant_stale_lock "$PROJECT_ROOT/.git/index.lock"

    local output
    output=$(run_fs_health_stderr sensitive)

    assert_contains "$output" "stale git index lock" \
        "A stale index.lock names the condition (issue #1086)"
    assert_contains "$output" "$PROJECT_ROOT/.git/index.lock" \
        "The report names the absolute lock path"
    assert_contains "$output" "1086" \
        "The report cites the issue so the diagnosis is findable"
    assert_contains "$output" "git -C $PROJECT_ROOT reset" \
        "The report carries the emptied-index recovery, not just the rm"
}

test_fresh_lock_is_silent() {
    # A lock younger than the cutoff is indistinguishable from a git command in
    # flight. Reporting it would tell someone to rm a live lock.
    seed_commit
    echo "live" >"$PROJECT_ROOT/.git/index.lock"

    local output
    output=$(run_fs_health_stderr sensitive)

    assert_not_contains "$output" "index lock" \
        "A just-created index.lock is treated as live and not reported"
}

test_no_lock_is_silent() {
    seed_commit

    local output
    output=$(run_fs_health_stderr sensitive)

    assert_not_contains "$output" "index lock" \
        "A repo without an index.lock produces no lock report"
}

test_lock_is_not_deleted() {
    # DIAGNOSTIC, not a repair: the lock may belong to another container on the
    # same mount, and the index beside it may be damaged.
    seed_commit
    plant_stale_lock "$PROJECT_ROOT/.git/index.lock"

    run_fs_health sensitive || true

    assert_file_exists "$PROJECT_ROOT/.git/index.lock" \
        "The diagnostic leaves the stale lock in place (issue #1086)"
}

test_stale_lock_does_not_fail_startup() {
    seed_commit
    plant_stale_lock "$PROJECT_ROOT/.git/index.lock"

    local rc=0
    run_fs_health sensitive || rc=$?

    assert_equals "0" "$rc" \
        "A stale index.lock never fails container startup"
}

test_linked_worktree_lock_is_reported() {
    # A linked worktree's .git is a FILE; its lock lives under the main repo's
    # .git/worktrees/<name>/, which a "$root/.git/index.lock" check never sees.
    seed_commit
    local wt="$PROJECT_ROOT/.worktrees/issue-1"
    git -C "$PROJECT_ROOT" worktree add -q -b wt-lock "$wt" >/dev/null 2>&1

    local wt_git_dir
    wt_git_dir=$(git -C "$wt" rev-parse --absolute-git-dir)
    plant_stale_lock "$wt_git_dir/index.lock"

    local output
    output=$(run_fs_health_stderr sensitive)

    assert_contains "$output" "$wt_git_dir/index.lock" \
        "A stale lock in a linked worktree's git dir is reported (issue #1086)"
}

test_emitted_rm_removes_a_spaced_lock_path() {
    # The rm line is meant to be pasted, so RUN it rather than pin its tokens —
    # on a repo whose path contains a space, where naive quoting breaks.
    local spaced="$TEST_TEMP_DIR/spaced repo"
    command mkdir -p "$spaced"
    git -C "$spaced" init -q .
    PROJECT_ROOT="$spaced"
    seed_commit
    plant_stale_lock "$spaced/.git/index.lock"

    local output emitted
    output=$(run_fs_health_stderr sensitive)
    emitted=$(command printf '%s\n' "$output" |
        /usr/bin/grep -F 'rm -f -- ' |
        /usr/bin/sed 's/^[^]]*\] *//')

    assert_contains "$emitted" "rm -f -- " \
        "The emitted rm line is recoverable from the report"

    eval "$emitted" >/dev/null 2>&1

    assert_file_not_exists "$spaced/.git/index.lock" \
        "The emitted rm removes a lock whose path contains a space"
}

test_skip_case_check_silences_lock_report() {
    seed_commit
    plant_stale_lock "$PROJECT_ROOT/.git/index.lock"

    local output
    output=$(SKIP_CASE_CHECK=true run_fs_health_stderr sensitive)

    assert_not_contains "$output" "index lock" \
        "SKIP_CASE_CHECK=true disables the lock diagnostic with the rest"
}

# ============================================================================
# Run all tests
# ============================================================================

run_test_with_setup test_stale_lock_is_reported "Stale index.lock is reported (#1086)"
run_test_with_setup test_fresh_lock_is_silent "Fresh index.lock stays silent (#1086)"
run_test_with_setup test_no_lock_is_silent "No index.lock, no report (#1086)"
run_test_with_setup test_lock_is_not_deleted "Lock diagnostic deletes nothing (#1086)"
run_test_with_setup test_stale_lock_does_not_fail_startup "Lock diagnostic never fails startup (#1086)"
run_test_with_setup test_linked_worktree_lock_is_reported "Linked worktree lock is reported (#1086)"
run_test_with_setup test_emitted_rm_removes_a_spaced_lock_path "Emitted rm handles a spaced path (#1086)"
run_test_with_setup test_skip_case_check_silences_lock_report "SKIP_CASE_CHECK silences the lock report (#1086)"

# Generate test report
generate_report
