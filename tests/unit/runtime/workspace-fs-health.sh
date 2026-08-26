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
    export TEST_TEMP_DIR="$TEST_SCRATCH_BASE/test-workspace-fs-health-$$"
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

    unset SKIP_CASE_CHECK SKIP_CASE_FIX FS_HEALTH_UPDATE_ENV FS_HEALTH_STAT \
        FS_HEALTH_MAX_DEPTH 2>/dev/null || true
}

teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
    unset PROJECT_ROOT TEST_TEMP_DIR SKIP_CASE_CHECK SKIP_CASE_FIX \
        FS_HEALTH_ENV_FILE FS_HEALTH_UPDATE_ENV FS_HEALTH_STAT \
        FS_HEALTH_MAX_DEPTH 2>/dev/null || true
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
        export FS_HEALTH_STAT="${FS_HEALTH_STAT:-/usr/bin/stat}"
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
        export FS_HEALTH_STAT="${FS_HEALTH_STAT:-/usr/bin/stat}"
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

test_snapshot_survives_quote_in_path() {
    # The snapshot is written as KEY='value' and read back by a parser. A path
    # containing a single quote must round-trip as DATA — if the quoting or the
    # unescaping is wrong, the value is truncated or (when sourced) the tail
    # becomes shell syntax.
    local quoted_root="$TEST_TEMP_DIR/my's-project"
    command mkdir -p "$quoted_root"
    git -C "$quoted_root" init -q .
    git -C "$quoted_root" config user.email "test@example.com"
    git -C "$quoted_root" config user.name "Test User"
    git -C "$quoted_root" config --unset core.ignorecase 2>/dev/null || true

    (
        export PROJECT_ROOT="$quoted_root"
        export FS_CASE_STATE=sensitive
        export FS_HEALTH_ENV_FILE
        bash "$FS_HEALTH_SCRIPT"
    ) 2>/dev/null

    # The cron leg must resolve the very same path back out of the snapshot.
    run_cron_wrapper insensitive >/dev/null

    local result
    result=$(git -C "$quoted_root" config --get core.ignorecase 2>/dev/null || echo "unset")
    assert_equals "true" "$result" \
        "A PROJECT_ROOT containing a single quote should round-trip through the snapshot"
}

test_snapshot_injection_not_executed() {
    # The reader must PARSE the snapshot, never source it. A crafted value is
    # the difference between a wrong string and arbitrary code on an hourly
    # timer, so assert the payload never runs.
    local canary="$TEST_TEMP_DIR/canary-executed"
    command printf "%s\n" \
        "PROJECT_ROOT='/nonexistent'; touch '$canary'" \
        "SKIP_CASE_FIX='false'" \
        >"$FS_HEALTH_ENV_FILE"

    run_cron_wrapper insensitive >/dev/null 2>&1

    assert_file_not_exists "$canary" \
        "Snapshot contents must never be executed as shell code"
}

test_snapshot_spaces_round_trip() {
    local spaced_root="$TEST_TEMP_DIR/my project dir"
    command mkdir -p "$spaced_root"
    git -C "$spaced_root" init -q .
    git -C "$spaced_root" config user.email "test@example.com"
    git -C "$spaced_root" config user.name "Test User"
    git -C "$spaced_root" config --unset core.ignorecase 2>/dev/null || true

    (
        export PROJECT_ROOT="$spaced_root"
        export FS_CASE_STATE=sensitive
        export FS_HEALTH_ENV_FILE
        bash "$FS_HEALTH_SCRIPT"
    ) 2>/dev/null

    run_cron_wrapper insensitive >/dev/null

    local result
    result=$(git -C "$spaced_root" config --get core.ignorecase 2>/dev/null || echo "unset")
    assert_equals "true" "$result" \
        "A PROJECT_ROOT containing spaces should round-trip through the snapshot"
}

test_cron_wrapper_noop_on_malformed_snapshot() {
    # Present but malformed (no usable PROJECT_ROOT) must be treated like no
    # snapshot, never as a license to fall back to cron's $PWD.
    command printf "%s\n" "SKIP_CASE_FIX='false'" >"$FS_HEALTH_ENV_FILE"

    local output
    output=$(run_cron_wrapper insensitive)
    assert_empty "$output" \
        "Cron wrapper should no-op on a snapshot with no PROJECT_ROOT"
    assert_equals "unset" "$(get_ignorecase)" \
        "Cron wrapper should repair nothing from a malformed snapshot"
}

test_cron_wrapper_noop_when_script_missing() {
    run_fs_health sensitive
    local output status=0
    output=$(
        unset PROJECT_ROOT SKIP_CASE_CHECK SKIP_CASE_FIX 2>/dev/null || true
        export FS_HEALTH_SCRIPT="$TEST_TEMP_DIR/no-such-script.sh"
        export FS_HEALTH_ENV_FILE
        export CRON_ENV_FILE="$TEST_TEMP_DIR/no-such-cron-env"
        { bash "$CRON_WRAPPER" >/dev/null; } 2>&1
    ) || status=$?
    assert_equals "0" "$status" \
        "Cron wrapper should exit 0 when the repair script is absent"
    assert_empty "$output" \
        "Cron wrapper should stay silent when the repair script is absent"
}

test_ondemand_fails_when_script_missing() {
    local status=0
    (
        export FS_HEALTH_SCRIPT="$TEST_TEMP_DIR/no-such-script.sh"
        export FS_HEALTH_ENV_FILE
        bash "$ONDEMAND_WRAPPER"
    ) >/dev/null 2>&1 || status=$?
    assert_equals "1" "$status" \
        "On-demand command should fail loudly when the repair script is absent"
}

test_ondemand_help_exits_clean() {
    local output status=0
    output=$(
        export FS_HEALTH_SCRIPT="$FS_HEALTH_SCRIPT"
        export FS_HEALTH_ENV_FILE
        bash "$ONDEMAND_WRAPPER" --help
    ) 2>&1 || status=$?
    assert_equals "0" "$status" "--help should exit 0"
    assert_contains "$output" "Usage:" "--help should print usage text"
}

# ============================================================================
# Root Re-Exec Tests (issue #800)
# ============================================================================
# Cron's user column is written at image build time, but the runtime user is
# not knowable then — editors remap it. So the /etc/cron.d entry runs this
# wrapper as ROOT and the wrapper resolves the container user hourly and drops
# to it. A baked build-time username fails SILENTLY (the job runs as a user
# that exists but has the wrong HOME, finds no snapshot, and exits 0), which is
# what these tests exist to keep from coming back.
#
# Running as root is not available in the test environment, so the root branch
# is driven through a PATH-shimmed `id` plus the wrapper's injectable
# FS_HEALTH_SU / FS_HEALTH_RESOLVE_USER_LIB seams.

# Build the stubs the root-path tests share. Sets STUB_BIN / SU_STUB / SU_LOG.
setup_root_stubs() {
    STUB_BIN="$TEST_TEMP_DIR/stub-bin"
    SU_STUB="$TEST_TEMP_DIR/su-stub"
    SU_LOG="$TEST_TEMP_DIR/su-called.log"
    command mkdir -p "$STUB_BIN"

    # `id -u` reporting 0 is what selects the root branch.
    command cat >"$STUB_BIN/id" <<'ID_STUB_EOF'
#!/bin/bash
[ "${1:-}" = "-u" ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
ID_STUB_EOF
    command chmod +x "$STUB_BIN/id"

    # Record the su invocation instead of actually switching user.
    command cat >"$SU_STUB" <<SU_STUB_EOF
#!/bin/bash
command printf '%s\n' "\$*" > "$SU_LOG"
SU_STUB_EOF
    command chmod +x "$SU_STUB"

    command cat >"$TEST_TEMP_DIR/resolver-ok.sh" <<'RESOLVER_EOF'
resolve_container_user() { command printf '%s\n' "resolved-user"; }
RESOLVER_EOF

    command cat >"$TEST_TEMP_DIR/resolver-fail.sh" <<'RESOLVER_FAIL_EOF'
resolve_container_user() { return 1; }
RESOLVER_FAIL_EOF
}

# Run the cron wrapper on the root branch. Args: $1=resolver lib, $2...=wrapper args.
# BASH_ENV must be cleared: /etc/bash_env rebuilds PATH on non-interactive
# bash, which would put the real `id` ahead of the shim and silently drop the
# test onto the non-root path (where it would trivially pass).
run_cron_wrapper_as_root() {
    local resolver="$1"
    shift
    (
        unset PROJECT_ROOT SKIP_CASE_CHECK SKIP_CASE_FIX 2>/dev/null || true
        export BASH_ENV=""
        export PATH="$STUB_BIN:$PATH"
        export FS_HEALTH_SU="$SU_STUB"
        export FS_HEALTH_RESOLVE_USER_LIB="$resolver"
        export FS_HEALTH_SCRIPT="$FS_HEALTH_SCRIPT"
        export FS_HEALTH_ENV_FILE
        export CRON_ENV_FILE="$TEST_TEMP_DIR/no-such-cron-env"
        bash "$CRON_WRAPPER" "$@"
    ) 2>&1
}

test_cron_wrapper_reexecs_as_resolved_user() {
    setup_root_stubs
    run_cron_wrapper_as_root "$TEST_TEMP_DIR/resolver-ok.sh" >/dev/null

    assert_file_exists "$SU_LOG" \
        "Root invocation should re-exec via su rather than run in place"
    local su_args
    su_args=$(command cat "$SU_LOG" 2>/dev/null)
    assert_contains "$su_args" "resolved-user" \
        "Re-exec should target the RESOLVED user, not a build-time name"
    assert_contains "$su_args" "--as-user" \
        "Re-exec should pass the --as-user loop guard"
    assert_contains "$su_args" "-l" \
        "Re-exec should use a login shell so HOME points at the resolved user"
}

test_cron_wrapper_as_user_does_not_reexec() {
    # The guard is an argument, not an env var, because su -l wipes the
    # environment — without it the second pass would re-exec forever.
    setup_root_stubs
    run_cron_wrapper_as_root "$TEST_TEMP_DIR/resolver-ok.sh" --as-user >/dev/null

    assert_file_not_exists "$SU_LOG" \
        "--as-user should suppress a second re-exec (loop guard)"
}

test_cron_wrapper_silent_when_user_unresolvable() {
    # Same posture as a missing snapshot: do not guess. A wrong guess would run
    # the repair's git-config and ln -sfn writes as the wrong owner.
    setup_root_stubs
    local output status=0
    output=$(run_cron_wrapper_as_root "$TEST_TEMP_DIR/resolver-fail.sh") || status=$?

    assert_equals "0" "$status" \
        "Root invocation should exit 0 when no container user resolves"
    assert_empty "$output" \
        "Root invocation should stay silent when no container user resolves"
    assert_file_not_exists "$SU_LOG" \
        "Root invocation should not re-exec when no container user resolves"
}

test_cron_wrapper_sources_cron_env_before_resolving() {
    # The wrapper must source CRON_ENV_FILE BEFORE resolving, so a CONTAINER_UID
    # exported there can reach the ladder's first arm. Sourcing it only after
    # the re-exec would leave that arm permanently dead under cron and silently
    # demote every run to the shape match — easy to reintroduce, hence a test.
    #
    # The resolver stub answers differently depending on whether CONTAINER_UID
    # is visible, so the resulting username proves the ordering.
    setup_root_stubs

    command cat >"$TEST_TEMP_DIR/cron-env-with-uid" <<'CRON_ENV_EOF'
export CONTAINER_UID=4242
CRON_ENV_EOF

    command cat >"$TEST_TEMP_DIR/resolver-uid-aware.sh" <<'RESOLVER_EOF'
resolve_container_user() {
    if [ -n "${CONTAINER_UID:-}" ]; then
        command printf '%s\n' "uid-arm-user"
    else
        command printf '%s\n' "shape-arm-user"
    fi
}
RESOLVER_EOF

    (
        unset PROJECT_ROOT SKIP_CASE_CHECK SKIP_CASE_FIX CONTAINER_UID 2>/dev/null || true
        export BASH_ENV=""
        export PATH="$STUB_BIN:$PATH"
        export FS_HEALTH_SU="$SU_STUB"
        export FS_HEALTH_RESOLVE_USER_LIB="$TEST_TEMP_DIR/resolver-uid-aware.sh"
        export FS_HEALTH_SCRIPT="$FS_HEALTH_SCRIPT"
        export FS_HEALTH_ENV_FILE
        export CRON_ENV_FILE="$TEST_TEMP_DIR/cron-env-with-uid"
        bash "$CRON_WRAPPER"
    ) >/dev/null 2>&1

    local su_args
    su_args=$(command cat "$SU_LOG" 2>/dev/null)
    assert_contains "$su_args" "uid-arm-user" \
        "CRON_ENV_FILE must be sourced before resolution so CONTAINER_UID reaches arm 1"
}

test_cron_wrapper_silent_when_resolver_lib_missing() {
    # Same silent-noop contract as a missing snapshot: if the shared resolver
    # sub-module is not on the image, the root leg has no safe way to pick a
    # user, so it does nothing rather than guessing.
    setup_root_stubs
    local output status=0
    output=$(run_cron_wrapper_as_root "$TEST_TEMP_DIR/no-such-resolver.sh") || status=$?

    assert_equals "0" "$status" \
        "Root invocation should exit 0 when the resolver lib is absent"
    assert_empty "$output" \
        "Root invocation should stay silent when the resolver lib is absent"
    assert_file_not_exists "$SU_LOG" \
        "Root invocation should not re-exec when the resolver lib is absent"
}

test_cron_wrapper_rejects_unknown_argument() {
    local output status=0
    output=$(
        export CRON_ENV_FILE="$TEST_TEMP_DIR/no-such-cron-env"
        export FS_HEALTH_ENV_FILE
        bash "$CRON_WRAPPER" --bogus 2>&1
    ) || status=$?

    assert_equals "2" "$status" "An unknown argument should exit 2"
    assert_contains "$output" "unknown argument" \
        "An unknown argument should say so on stderr"
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
run_test_with_setup test_predicate_nlink_zero_repairs "Predicate: nlink=0 arm repairs"
run_test_with_setup test_predicate_size_zero_repairs "Predicate: st_size=0 arm repairs"
run_test_with_setup test_predicate_healthy_stat_untouched "Predicate: healthy stat untouched"
run_test_with_setup test_predicate_ignores_missing_link "Predicate: missing link never recreated"
run_test_with_setup test_superproject_index_hides_submodule_links "Superproject index hides submodule links"
run_test_with_setup test_submodule_symlink_repaired "Stale symlink inside a submodule is repaired"
run_test_with_setup test_submodule_ignorecase_aligned "Submodule core.ignorecase aligned"
run_test_with_setup test_nested_submodule_reached "Nested submodule reached recursively"
run_test_with_setup test_depth_cap_stops_recursion "Depth cap stops recursion"
run_test_with_setup test_depth_cap_rejects_non_numeric "Non-numeric depth cap falls back to default"
run_test_with_setup test_uninitialized_submodule_is_silent "Uninitialized submodule is silent and non-fatal"
run_test_with_setup test_healthy_submodule_leaves_tree_clean "Healthy submodule leaves tree clean"
run_test_with_setup test_skip_fix_reports_submodule_without_writing "SKIP_CASE_FIX reports submodule without writing"
run_test_with_setup test_skip_check_does_nothing_with_submodule "SKIP_CASE_CHECK skips the submodule pass"
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
run_test_with_setup test_snapshot_survives_quote_in_path "Snapshot round-trips a path with a single quote"
run_test_with_setup test_snapshot_injection_not_executed "Snapshot contents are never executed"
run_test_with_setup test_snapshot_spaces_round_trip "Snapshot round-trips a path with spaces"
run_test_with_setup test_cron_wrapper_noop_on_malformed_snapshot "Cron wrapper no-ops on a malformed snapshot"
run_test_with_setup test_cron_wrapper_noop_when_script_missing "Cron wrapper no-ops when the script is absent"
run_test_with_setup test_ondemand_fails_when_script_missing "On-demand command fails when the script is absent"
run_test_with_setup test_ondemand_help_exits_clean "On-demand --help exits cleanly"
run_test_with_setup test_ondemand_rejects_bad_path "On-demand command rejects a bad path"
run_test_with_setup test_cron_wrapper_reexecs_as_resolved_user "Root cron leg re-execs as the resolved user"
run_test_with_setup test_cron_wrapper_as_user_does_not_reexec "--as-user suppresses a second re-exec"
run_test_with_setup test_cron_wrapper_silent_when_user_unresolvable "Root cron leg silent when no user resolves"
run_test_with_setup test_cron_wrapper_sources_cron_env_before_resolving "Cron env is sourced before user resolution"
run_test_with_setup test_cron_wrapper_silent_when_resolver_lib_missing "Root cron leg silent when the resolver lib is absent"
run_test_with_setup test_cron_wrapper_rejects_unknown_argument "Cron wrapper rejects an unknown argument"

# Generate test report
generate_report
