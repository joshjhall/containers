#!/usr/bin/env bash
# Unit tests for lib/runtime/42-workspace-fs-health.sh — linked worktree
# traversal (issue #882).
#
# A linked worktree is a third root class, invisible to both existing
# enumerations: it is not in the superproject's index (so `ls-files` never names
# it) and it is not a gitlink (so the submodule walk never descends into it).
# Every fresh golem worktree therefore arrived with its tracked symlinks already
# reading as modified.
#
# Sibling-file shape follows the precedent set by
# workspace-fs-health-submodules.sh and workspace-fs-health-cron-entry.sh.

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Workspace FS Health Linked Worktree Tests"

# Shared fixtures: FS_HEALTH_SCRIPT, setup/teardown, run_fs_health,
# run_fs_health_stderr, get_ignorecase, seed_symlinks, run_test_with_setup.
# Sourced after init_test_framework — setup() reads TEST_SCRATCH_BASE.
source "$(dirname "${BASH_SOURCE[0]}")/../../framework/helpers/workspace-fs-health.sh"

# ============================================================================
# Fixtures
# ============================================================================

# Install a stat stub that reports "$1" for every symlink it is asked about and
# defers to the real stat otherwise. Sets FS_HEALTH_STAT.
#
# nlink=0 and st_size=0 are filesystem cache artifacts that cannot be produced
# on demand, so substituting the probe is the only way to exercise the repair
# rather than just its inaction. Same seam the submodule suite uses.
# Args: $1 = the "%h %s" string to report (e.g. "0 7", "1 0")
stub_stat() {
    local reported="$1"
    local stub="$TEST_TEMP_DIR/stat-stub"

    command cat >"$stub" <<STAT_STUB_EOF
#!/bin/bash
# Only intercept the exact '-c %h %s' probe on a symlink; everything else
# falls through, so an unrelated stat call in the script under test is not
# silently given fabricated numbers.
if [ "\$1" = "-c" ] && [ "\$2" = '%h %s' ] && [ -L "\$3" ]; then
    command printf '%s\n' "$reported"
    exit 0
fi
exec /usr/bin/stat "\$@"
STAT_STUB_EOF
    command chmod +x "$stub"
    export FS_HEALTH_STAT="$stub"
}

# Add a linked worktree containing a tracked symlink, mirroring the real
# .worktrees/issue-N layout the golem flow creates.
#
# The symlink is committed on the NEW BRANCH rather than seeded in the parent,
# so the fixture does not depend on seed_symlinks having run and the worktree
# has content of its own.
#
# Args: $1 = path within the project (e.g. ".worktrees/issue-882")
# Echoes the worktree's absolute path.
add_worktree() {
    local rel="$1"
    local wt="$PROJECT_ROOT/$rel"
    local branch="wt-${rel//\//-}"

    # A worktree cannot be added from a repo with no commits.
    if ! git -C "$PROJECT_ROOT" rev-parse HEAD >/dev/null 2>&1; then
        echo "base" >"$PROJECT_ROOT/base.txt"
        git -C "$PROJECT_ROOT" add -A >/dev/null 2>&1
        git -C "$PROJECT_ROOT" commit -qm "base commit" >/dev/null 2>&1
    fi

    git -C "$PROJECT_ROOT" worktree add -q -b "$branch" "$wt" >/dev/null 2>&1

    echo "wt content" >"$wt/CLAUDE.md"
    command ln -s CLAUDE.md "$wt/AGENTS.md"
    git -C "$wt" add -A >/dev/null 2>&1
    git -C "$wt" commit -qm "seed worktree symlink" >/dev/null 2>&1

    command printf '%s\n' "$wt"
}

# ============================================================================
# Premise
# ============================================================================

test_superproject_index_hides_worktree_links() {
    # The bug itself, pinned: this is what the existing enumerations see. If it
    # ever stops holding, the traversal below is solving a problem that moved.
    add_worktree ".worktrees/issue-882" >/dev/null

    local matches
    matches=$(git -C "$PROJECT_ROOT" ls-files -s 2>/dev/null |
        /usr/bin/awk -F'\t' '$1 ~ /^(120000|160000) / { print $2 }' |
        /usr/bin/grep -c ".worktrees/" || true)

    assert_equals "0" "$matches" \
        "Superproject ls-files must not enumerate a linked worktree (the #882 premise)"
}

# ============================================================================
# Repair
# ============================================================================

test_worktree_symlink_repaired() {
    local wt
    wt=$(add_worktree ".worktrees/issue-882")
    stub_stat "0 7"

    local output
    output=$(run_fs_health_stderr sensitive)

    assert_contains "$output" ".worktrees/issue-882/AGENTS.md" \
        "A stale symlink inside a linked worktree should be found and reported"
    assert_contains "$output" "refreshed .worktrees/issue-882/AGENTS.md" \
        "A stale symlink inside a linked worktree should be repaired"
    assert_equals "CLAUDE.md" "$(command readlink "$wt/AGENTS.md")" \
        "Worktree symlink target must be preserved"
}

test_multiple_worktrees_all_reached() {
    # The list is flat, so every entry must be visited — not just the first.
    add_worktree ".worktrees/issue-100" >/dev/null
    add_worktree ".worktrees/issue-200" >/dev/null
    stub_stat "0 7"

    local output
    output=$(run_fs_health_stderr sensitive)

    assert_contains "$output" "refreshed .worktrees/issue-100/AGENTS.md" \
        "The first linked worktree should be repaired"
    assert_contains "$output" "refreshed .worktrees/issue-200/AGENTS.md" \
        "The second linked worktree should be repaired too"
}

test_superproject_still_repaired_alongside() {
    # The worktree pass is additive: it must not displace the main root's own
    # repair.
    seed_symlinks
    add_worktree ".worktrees/issue-882" >/dev/null
    stub_stat "0 7"

    local output
    output=$(run_fs_health_stderr sensitive)

    assert_contains "$output" "refreshed good.link" \
        "The superproject's own symlinks must still be repaired"
    assert_contains "$output" "refreshed .worktrees/issue-882/AGENTS.md" \
        "The linked worktree must be repaired in the same pass"
}

test_healthy_worktree_leaves_tree_clean() {
    local wt
    wt=$(add_worktree ".worktrees/issue-882")

    local output
    output=$(run_fs_health_stderr sensitive)
    assert_empty "$output" \
        "A healthy linked worktree should produce no output"

    local wt_status
    wt_status=$(git -C "$wt" status --porcelain 2>/dev/null)
    assert_empty "$wt_status" \
        "The worktree should stay clean after a no-op pass"
}

test_worktree_ignorecase_aligned() {
    # Worktrees SHARE .git/config, so this write is the same one the main root
    # makes. Asserted anyway because the alignment must hold when reached
    # through the worktree root, and the shared config is what makes the repeat
    # idempotent and silent rather than a second report.
    add_worktree ".worktrees/issue-882" >/dev/null
    git -C "$PROJECT_ROOT" config --unset core.ignorecase 2>/dev/null || true

    run_fs_health insensitive

    assert_equals "true" "$(get_ignorecase)" \
        "core.ignorecase should be aligned with a linked worktree present"
}

# ============================================================================
# Anti-recursion gate
# ============================================================================

test_run_from_worktree_does_not_enumerate_siblings() {
    # `git worktree list` is repo-GLOBAL: asked from inside a linked worktree it
    # returns the whole set, including the caller. Without the
    # main-worktree-only gate this run would repair its own root twice and sweep
    # in every sibling. Pins that gate.
    local wt_a
    wt_a=$(add_worktree ".worktrees/issue-100")
    add_worktree ".worktrees/issue-200" >/dev/null
    stub_stat "0 7"

    local output
    output=$(PROJECT_ROOT="$wt_a" run_fs_health_stderr sensitive)

    assert_contains "$output" "refreshed AGENTS.md" \
        "Running against a worktree should repair that worktree's own links"
    assert_not_contains "$output" "issue-200" \
        "Running against a worktree must not enumerate its siblings"
    assert_not_contains "$output" ".worktrees/issue-100" \
        "Running against a worktree must not re-enter itself as a linked worktree"
}

# ============================================================================
# Degenerate entries
# ============================================================================

test_deleted_worktree_dir_is_silent() {
    # A worktree whose directory was removed but not pruned stays in the list.
    # It must be a silent non-event, not a warning and not a failure — the same
    # treatment an uninitialized submodule gets.
    local wt
    wt=$(add_worktree ".worktrees/issue-882")
    command rm -rf "$wt"
    stub_stat "0 7"

    local output status=0
    output=$(run_fs_health_stderr sensitive) || status=$?

    assert_equals "0" "$status" \
        "A pruned-but-registered worktree must never make the run fail"
    assert_empty "$output" \
        "A pruned-but-registered worktree should produce no output"
}

test_no_worktrees_is_silent() {
    # The overwhelmingly common case: a project with no linked worktrees at all
    # must be unchanged by this pass.
    seed_symlinks

    local output status=0
    output=$(run_fs_health_stderr sensitive) || status=$?

    assert_equals "0" "$status" \
        "A project with no linked worktrees must not fail"
    assert_empty "$output" \
        "A project with no linked worktrees should produce no output"
}

# ============================================================================
# Opt-outs
# ============================================================================

test_skip_fix_reports_worktree_without_writing() {
    local wt
    wt=$(add_worktree ".worktrees/issue-882")
    stub_stat "0 7"
    export SKIP_CASE_FIX=true

    local before output
    before=$(/usr/bin/stat -c '%Y' "$wt/AGENTS.md" 2>/dev/null)
    output=$(run_fs_health_stderr sensitive)

    assert_contains "$output" ".worktrees/issue-882/AGENTS.md" \
        "SKIP_CASE_FIX should still REPORT a linked-worktree finding"
    assert_contains "$output" "not repairing" \
        "SKIP_CASE_FIX should say it is not repairing"
    assert_not_contains "$output" "refreshed .worktrees/issue-882/AGENTS.md" \
        "SKIP_CASE_FIX must not relink a worktree symlink"
    assert_equals "$before" "$(/usr/bin/stat -c '%Y' "$wt/AGENTS.md" 2>/dev/null)" \
        "SKIP_CASE_FIX must leave the worktree link's mtime untouched"
}

test_skip_check_does_nothing_with_worktree() {
    local wt
    wt=$(add_worktree ".worktrees/issue-882")
    stub_stat "0 7"
    export SKIP_CASE_CHECK=true

    local before output
    before=$(/usr/bin/stat -c '%Y' "$wt/AGENTS.md" 2>/dev/null)
    output=$(run_fs_health_stderr insensitive)

    assert_empty "$output" \
        "SKIP_CASE_CHECK must silence the linked-worktree pass entirely"
    assert_equals "$before" "$(/usr/bin/stat -c '%Y' "$wt/AGENTS.md" 2>/dev/null)" \
        "SKIP_CASE_CHECK must not touch a worktree symlink"

    local result
    result=$(get_ignorecase)
    assert_equals "unset" "$result" \
        "SKIP_CASE_CHECK must not write core.ignorecase"
}

# ============================================================================
# Run all tests
# ============================================================================

run_test_with_setup test_superproject_index_hides_worktree_links "Superproject index hides linked worktrees"
run_test_with_setup test_worktree_symlink_repaired "Stale symlink inside a linked worktree is repaired"
run_test_with_setup test_multiple_worktrees_all_reached "Every linked worktree is reached"
run_test_with_setup test_superproject_still_repaired_alongside "Superproject still repaired alongside worktrees"
run_test_with_setup test_healthy_worktree_leaves_tree_clean "Healthy worktree leaves tree clean"
run_test_with_setup test_worktree_ignorecase_aligned "core.ignorecase aligned with a worktree present"
run_test_with_setup test_run_from_worktree_does_not_enumerate_siblings "Running from a worktree does not enumerate siblings"
run_test_with_setup test_deleted_worktree_dir_is_silent "Pruned-but-registered worktree is silent and non-fatal"
run_test_with_setup test_no_worktrees_is_silent "Project with no linked worktrees is silent"
run_test_with_setup test_skip_fix_reports_worktree_without_writing "SKIP_CASE_FIX reports worktree without writing"
run_test_with_setup test_skip_check_does_nothing_with_worktree "SKIP_CASE_CHECK skips the worktree pass"

# Generate test report
generate_report
