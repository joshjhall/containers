#!/usr/bin/env bash
# Unit tests for lib/runtime/42-workspace-fs-health.sh — staleness predicate
# and submodule traversal (issue #827).
#
# Split out of tests/unit/runtime/workspace-fs-health.sh in issue #832. Both
# concerns here are driven through injectable seams the rest of the suite does
# not use (FS_HEALTH_STAT for the predicate, real nested submodule fixtures for
# the traversal), and neither is referenced by the ignorecase, symlink, cron, or
# root-re-exec sections that stay behind. The sibling-file shape follows the
# precedent already set by workspace-fs-health-cron-entry.sh.

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Workspace FS Health Submodule Tests"

# Shared fixtures: FS_HEALTH_SCRIPT, setup/teardown, run_fs_health,
# run_fs_health_stderr, get_ignorecase, seed_symlinks, run_test_with_setup.
# Sourced after init_test_framework — setup() reads TEST_SCRATCH_BASE.
source "$(dirname "${BASH_SOURCE[0]}")/../../framework/helpers/workspace-fs-health.sh"

# ============================================================================
# Staleness Predicate Tests (issue #827)
# ============================================================================
# nlink=0 and st_size=0 are filesystem cache artifacts — they cannot be created
# on demand, which is why every test above can only assert the guard's
# INACTION. The FS_HEALTH_STAT seam substitutes the probe so both arms of the
# predicate, and the healthy case, are exercised for real.

# Install a stat stub that reports "$1" for every symlink it is asked about and
# defers to the real stat otherwise. Sets FS_HEALTH_STAT.
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

test_predicate_nlink_zero_repairs() {
    seed_symlinks
    stub_stat "0 7"

    local output
    output=$(run_fs_health_stderr sensitive)

    assert_contains "$output" "nlink=0" \
        "The nlink=0 arm should fire and name itself in the report"
    assert_contains "$output" "refreshed good.link" \
        "A link reporting nlink=0 should be relinked"
    assert_equals "realfile.txt" "$(command readlink "$PROJECT_ROOT/good.link")" \
        "Repair must preserve the original target"
}

test_predicate_size_zero_repairs() {
    # The arm #827 actually needs: git sizes a symlink from st_size before
    # reading it, so size=0 alone makes git diff the link against the empty
    # blob — regardless of what nlink says.
    seed_symlinks
    stub_stat "1 0"

    local output
    output=$(run_fs_health_stderr sensitive)

    assert_contains "$output" "st_size=0" \
        "The st_size=0 arm should fire even though nlink is healthy"
    assert_contains "$output" "refreshed good.link" \
        "A link reporting st_size=0 with a real target should be relinked"
    assert_equals "realfile.txt" "$(command readlink "$PROJECT_ROOT/good.link")" \
        "Repair must preserve the original target"
}

test_predicate_healthy_stat_untouched() {
    # Plausible healthy numbers must not trip either arm.
    seed_symlinks
    stub_stat "1 12"

    local output
    output=$(run_fs_health_stderr sensitive)

    assert_empty "$output" \
        "A healthy nlink/size pair should produce no output at all"
}

test_predicate_ignores_missing_link() {
    # The st_size=0 arm fires on anything the stub reports, so the guards AHEAD
    # of the probe carry the safety. This pins the first of them: a tracked
    # symlink that is no longer on disk (deleted, or a path git knows about but
    # the worktree does not) is dropped by [ -L ] and must never be recreated —
    # the repair refreshes attributes, it does not restore files.
    #
    # The probe's own non-empty-target conjunct cannot be reached from a real
    # filesystem (readlink on a live symlink always returns its target), so it
    # is a defensive invariant rather than a testable branch.
    seed_symlinks
    stub_stat "1 0"

    command rm -f "$PROJECT_ROOT/good.link"

    local output
    output=$(run_fs_health_stderr sensitive)

    assert_not_contains "$output" "good.link" \
        "A symlink missing from disk must not be reported or recreated"
    assert_file_not_exists "$PROJECT_ROOT/good.link" \
        "The repair must never resurrect a deleted symlink"
}

# ============================================================================
# Submodule Traversal Tests (issue #827)
# ============================================================================
# `git ls-files` stops at a 160000 gitlink, so a superproject-only pass never
# enumerates a submodule's symlinks and they decay forever. These cover the
# recursive walk that fixes it.

# Build a submodule containing tracked symlinks and add it to $PROJECT_ROOT.
# Args: $1 = path within the superproject (e.g. "containers")
# Echoes the submodule's absolute worktree path.
add_submodule() {
    local name="$1"
    local origin="$TEST_TEMP_DIR/origin-${name//\//-}"

    command mkdir -p "$origin"
    git -C "$origin" init -q .
    git -C "$origin" config user.email "test@example.com"
    git -C "$origin" config user.name "Test User"
    git -C "$origin" config --unset core.ignorecase 2>/dev/null || true

    echo "sub content" >"$origin/CLAUDE.md"
    command ln -s CLAUDE.md "$origin/AGENTS.md"
    git -C "$origin" add -A >/dev/null 2>&1
    git -C "$origin" commit -qm "seed submodule" >/dev/null 2>&1

    # git 2.38+ refuses file:// submodules unless this is set. Without it the
    # add fails and the fixture is silently empty — every assertion below would
    # then pass vacuously.
    git -C "$PROJECT_ROOT" -c protocol.file.allow=always \
        submodule add -q "$origin" "$name" >/dev/null 2>&1
    git -C "$PROJECT_ROOT" commit -qm "add submodule $name" >/dev/null 2>&1

    command printf '%s\n' "$PROJECT_ROOT/$name"
}

test_superproject_index_hides_submodule_links() {
    # The bug itself, pinned: this is what the old enumeration saw. If this ever
    # stops holding, the traversal below is solving a problem that moved.
    add_submodule "containers" >/dev/null

    local matches
    matches=$(git -C "$PROJECT_ROOT" ls-files -s 2>/dev/null |
        /usr/bin/awk -F'\t' '$1 ~ /^120000 / { print $2 }' |
        /usr/bin/grep -c "containers/" || true)

    assert_equals "0" "$matches" \
        "Superproject ls-files must not enumerate submodule symlinks (the #827 premise)"
}

test_submodule_symlink_repaired() {
    local sub
    sub=$(add_submodule "containers")
    stub_stat "0 7"

    local output
    output=$(run_fs_health_stderr sensitive)

    assert_contains "$output" "containers/AGENTS.md" \
        "A stale symlink inside a submodule should be found and reported"
    assert_contains "$output" "refreshed containers/AGENTS.md" \
        "A stale symlink inside a submodule should be repaired"
    assert_equals "CLAUDE.md" "$(command readlink "$sub/AGENTS.md")" \
        "Submodule symlink target must be preserved"
}

test_submodule_ignorecase_aligned() {
    local sub
    sub=$(add_submodule "containers")
    git -C "$sub" config --unset core.ignorecase 2>/dev/null || true

    run_fs_health insensitive

    local result
    result=$(git -C "$sub" config --get core.ignorecase 2>/dev/null || echo "unset")
    assert_equals "true" "$result" \
        "A submodule's own core.ignorecase should be aligned too"
    assert_equals "true" "$(get_ignorecase)" \
        "Superproject alignment must still happen alongside it"
}

test_nested_submodule_reached() {
    # Two levels deep: the walk must recurse, not just look one layer down.
    seed_nested_submodules >/dev/null

    stub_stat "0 7"
    local output
    output=$(run_fs_health_stderr sensitive)

    assert_contains "$output" "outer/inner/AGENTS.md" \
        "The walk should recurse into a nested submodule and label it by full path"
}

# Build a superproject -> outer -> inner chain and echo the inner worktree path.
# Shared by the nesting and depth-cap tests.
seed_nested_submodules() {
    local outer inner_origin
    outer=$(add_submodule "outer")

    inner_origin="$TEST_TEMP_DIR/origin-inner-nested"
    command mkdir -p "$inner_origin"
    git -C "$inner_origin" init -q .
    git -C "$inner_origin" config user.email "test@example.com"
    git -C "$inner_origin" config user.name "Test User"
    echo "deep" >"$inner_origin/CLAUDE.md"
    command ln -s CLAUDE.md "$inner_origin/AGENTS.md"
    git -C "$inner_origin" add -A >/dev/null 2>&1
    git -C "$inner_origin" commit -qm "seed inner" >/dev/null 2>&1

    git -C "$outer" -c protocol.file.allow=always \
        submodule add -q "$inner_origin" "inner" >/dev/null 2>&1
    git -C "$outer" commit -qm "add inner" >/dev/null 2>&1

    command printf '%s\n' "$outer/inner"
}

test_depth_cap_stops_recursion() {
    # The cap is the one branch added purely to bound a bad outcome, so it must
    # be shown to actually stop the walk rather than existing as dead code.
    # Depth 1 admits the superproject (depth 0) and outer (depth 1) but must
    # stop before inner.
    seed_nested_submodules >/dev/null
    stub_stat "0 7"
    export FS_HEALTH_MAX_DEPTH=1

    local output status=0
    output=$(run_fs_health_stderr sensitive) || status=$?

    assert_equals "0" "$status" \
        "Hitting the depth cap must not make the run fail"
    assert_contains "$output" "outer/AGENTS.md" \
        "Depth 1 should still reach the first-level submodule"
    assert_not_contains "$output" "outer/inner/AGENTS.md" \
        "Depth 1 must stop before the second-level submodule"
}

test_depth_cap_zero_skips_all_submodules() {
    # 0 is a distinct path from 1: the recursion loop body never runs at all.
    # It is also the natural way to disable submodule traversal alone, without
    # SKIP_CASE_CHECK switching off the superproject repair too.
    seed_nested_submodules >/dev/null
    stub_stat "0 7"
    export FS_HEALTH_MAX_DEPTH=0

    local output status=0
    output=$(run_fs_health_stderr sensitive) || status=$?

    assert_equals "0" "$status" \
        "Depth 0 must not make the run fail"
    assert_not_contains "$output" "outer/" \
        "Depth 0 must not descend into any submodule"
}

test_depth_cap_rejects_non_numeric() {
    # A non-integer would make `[ -lt ]` both noisy AND false, silently
    # disabling submodule traversal. It must fall back to the default instead.
    seed_nested_submodules >/dev/null
    stub_stat "0 7"
    export FS_HEALTH_MAX_DEPTH="not-a-number"

    local output status=0
    output=$(run_fs_health_stderr sensitive) || status=$?

    assert_equals "0" "$status" \
        "A bad FS_HEALTH_MAX_DEPTH must not make the run fail"
    assert_not_contains "$output" "integer expression expected" \
        "A bad FS_HEALTH_MAX_DEPTH must not leak a bash error to stderr"
    assert_contains "$output" "outer/inner/AGENTS.md" \
        "A bad FS_HEALTH_MAX_DEPTH should fall back to the default, not disable traversal"
}

test_uninitialized_submodule_is_silent() {
    # The gitlink is in the index whether or not the submodule was ever cloned.
    # An uninitialized one must be a silent non-event, not a warning or error.
    add_submodule "containers" >/dev/null
    command rm -rf "$PROJECT_ROOT/containers"
    command mkdir -p "$PROJECT_ROOT/containers"

    local output status=0
    output=$(run_fs_health_stderr sensitive) || status=$?

    assert_equals "0" "$status" \
        "An uninitialized submodule must never make the run fail"
    assert_empty "$output" \
        "An uninitialized submodule should produce no output"
}

test_healthy_submodule_leaves_tree_clean() {
    local sub
    sub=$(add_submodule "containers")

    local output
    output=$(run_fs_health_stderr sensitive)
    assert_empty "$output" \
        "A healthy submodule should produce no output"

    local sub_status super_status
    sub_status=$(git -C "$sub" status --porcelain 2>/dev/null)
    super_status=$(git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null)
    assert_empty "$sub_status" "Submodule should stay clean after a no-op pass"
    assert_empty "$super_status" "Superproject should stay clean after a no-op pass"
}

test_skip_fix_reports_submodule_without_writing() {
    local sub
    sub=$(add_submodule "containers")
    stub_stat "0 7"
    export SKIP_CASE_FIX=true

    local before output
    before=$(/usr/bin/stat -c '%Y' "$sub/AGENTS.md" 2>/dev/null)
    output=$(run_fs_health_stderr sensitive)

    assert_contains "$output" "containers/AGENTS.md" \
        "SKIP_CASE_FIX should still REPORT a submodule finding"
    assert_contains "$output" "not repairing" \
        "SKIP_CASE_FIX should say it is not repairing"
    assert_not_contains "$output" "refreshed containers/AGENTS.md" \
        "SKIP_CASE_FIX must not relink a submodule symlink"
    assert_equals "$before" "$(/usr/bin/stat -c '%Y' "$sub/AGENTS.md" 2>/dev/null)" \
        "SKIP_CASE_FIX must leave the submodule link's mtime untouched"

    local result
    result=$(git -C "$sub" config --get core.ignorecase 2>/dev/null || echo "unset")
    assert_equals "unset" "$result" \
        "SKIP_CASE_FIX must not write a submodule's core.ignorecase"
}

test_skip_check_does_nothing_with_submodule() {
    local sub
    sub=$(add_submodule "containers")
    stub_stat "0 7"
    export SKIP_CASE_CHECK=true

    local output
    output=$(run_fs_health_stderr insensitive)

    assert_empty "$output" \
        "SKIP_CASE_CHECK must silence the submodule pass entirely"

    local result
    result=$(git -C "$sub" config --get core.ignorecase 2>/dev/null || echo "unset")
    assert_equals "unset" "$result" \
        "SKIP_CASE_CHECK must not touch a submodule's config"
}

# ============================================================================
# Run all tests
# ============================================================================

run_test_with_setup test_predicate_nlink_zero_repairs "Predicate: nlink=0 arm repairs"
run_test_with_setup test_predicate_size_zero_repairs "Predicate: st_size=0 arm repairs"
run_test_with_setup test_predicate_healthy_stat_untouched "Predicate: healthy stat untouched"
run_test_with_setup test_predicate_ignores_missing_link "Predicate: missing link never recreated"
run_test_with_setup test_superproject_index_hides_submodule_links "Superproject index hides submodule links"
run_test_with_setup test_submodule_symlink_repaired "Stale symlink inside a submodule is repaired"
run_test_with_setup test_submodule_ignorecase_aligned "Submodule core.ignorecase aligned"
run_test_with_setup test_nested_submodule_reached "Nested submodule reached recursively"
run_test_with_setup test_depth_cap_stops_recursion "Depth cap stops recursion"
run_test_with_setup test_depth_cap_zero_skips_all_submodules "Depth cap of 0 skips all submodules"
run_test_with_setup test_depth_cap_rejects_non_numeric "Non-numeric depth cap falls back to default"
run_test_with_setup test_uninitialized_submodule_is_silent "Uninitialized submodule is silent and non-fatal"
run_test_with_setup test_healthy_submodule_leaves_tree_clean "Healthy submodule leaves tree clean"
run_test_with_setup test_skip_fix_reports_submodule_without_writing "SKIP_CASE_FIX reports submodule without writing"
run_test_with_setup test_skip_check_does_nothing_with_submodule "SKIP_CASE_CHECK skips the submodule pass"

# Generate test report
generate_report
