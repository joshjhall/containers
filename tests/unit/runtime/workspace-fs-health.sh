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

# Shared fixtures: FS_HEALTH_SCRIPT, setup/teardown, run_fs_health,
# run_fs_health_stderr, get_ignorecase, seed_symlinks, run_test_with_setup.
# Sourced after init_test_framework — setup() reads TEST_SCRATCH_BASE.
# The staleness-predicate and submodule-traversal coverage lives in the sibling
# workspace-fs-health-submodules.sh, which sources the same fragment (#832).
source "$(dirname "${BASH_SOURCE[0]}")/../../framework/helpers/workspace-fs-health.sh"

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
# Config-injection immunity (issue #894)
# ============================================================================
#
# check_ignorecase reads core.ignorecase and returns early — SILENTLY — when the
# value is already "true". Git resolves config from the environment ahead of
# `-C`, so an inherited GIT_CONFIG_COUNT or GIT_CONFIG_GLOBAL supplying that
# value makes the repair no-op with no diagnostic at all: the same silent-failure
# class #886 was filed to close, reached through the config family rather than
# the repo-identity one.
#
# The stakes are in the script's own header: on a case-insensitive mount, an
# unrepaired core.ignorecase lets `git clean -fd` unlink the shared inode and
# destroy tracked source.
#
# These assertions read the repo-LOCAL value deliberately — plain
# `get_ignorecase` resolves the injected value too, so it would report "true"
# for a repair that never happened and the test would pass while the bug was
# live.

# The repo-local core.ignorecase, ignoring any injected/global value.
get_local_ignorecase() {
    git -C "$PROJECT_ROOT" config --local --get core.ignorecase 2>/dev/null ||
        command echo "unset"
}

test_config_count_injection_does_not_suppress_repair() {
    # The indexed-pair mechanism. Clearing GIT_CONFIG_COUNT is what neutralizes
    # it — git ignores GIT_CONFIG_KEY_<n>/VALUE_<n> without a count — so no
    # unbounded enumeration of _<n> names is required.
    local output
    output=$(GIT_CONFIG_COUNT=1 \
        GIT_CONFIG_KEY_0=core.ignorecase \
        GIT_CONFIG_VALUE_0=true \
        run_fs_health_stderr insensitive)

    assert_equals "true" "$(get_local_ignorecase)" \
        "An injected core.ignorecase must not suppress the repo-local repair"
    assert_contains "$output" "case-insensitive" \
        "The repair must still report, not vanish silently"
}

test_config_global_injection_does_not_suppress_repair() {
    # The other spelling of the same hijack: a substituted global config file.
    #
    # Weaker than the GIT_CONFIG / GIT_CONFIG_PARAMETERS vectors, and the
    # fixture's shape is what makes it fire: global config LOSES to a repo-local
    # value, so it can only suppress the repair on a repo that has no local
    # core.ignorecase yet — which is exactly this fixture (setup() unsets it).
    # Seeding a local value here would make the test pass for the wrong reason.
    command printf '[core]\n\tignorecase = true\n' >"$TEST_TEMP_DIR/injected-gitconfig"

    run_fs_health_with_global_config "$TEST_TEMP_DIR/injected-gitconfig" insensitive

    assert_equals "true" "$(get_local_ignorecase)" \
        "A substituted GIT_CONFIG_GLOBAL must not suppress the repo-local repair"
}

test_config_parameters_injection_does_not_suppress_repair() {
    # The likeliest vector, and the strongest: git populates
    # GIT_CONFIG_PARAMETERS itself for every `git -c key=value`, exporting it to
    # child processes. So an ancestor `git -c` — a hook, an alias, a wrapper, a
    # CI step — reaches this script with nobody having deliberately exported a
    # GIT_* var.
    #
    # It is also the only one that outranks the repo-LOCAL file, so this test
    # seeds core.ignorecase=false first: that is the state check_ignorecase
    # exists to correct, and the injection must not be able to mask it.
    git -C "$PROJECT_ROOT" config --local core.ignorecase false

    local output
    output=$(GIT_CONFIG_PARAMETERS="'core.ignorecase'='true'" \
        run_fs_health_stderr insensitive)

    assert_equals "true" "$(get_local_ignorecase)" \
        "An injected GIT_CONFIG_PARAMETERS must not mask an explicitly wrong local value"
    assert_contains "$output" "case-insensitive" \
        "The repair must still report, not vanish silently"
}

test_legacy_git_config_does_not_divert_the_write() {
    # The legacy singular GIT_CONFIG affects only the `git config` subcommand —
    # exactly what check_ignorecase uses, twice, with no --file — and it diverts
    # the WRITE as well as the read.
    #
    # This is the only vector in the set whose failure is not silent: measured
    # end-to-end, the script reported "set core.ignorecase=true" while the
    # repo-local value stayed `false`. A FALSE SUCCESS is worse than a silent
    # no-op, because the log actively tells an operator the repair landed.
    #
    # So this test seeds core.ignorecase=false and asserts BOTH halves: the
    # repo-local value is really corrected, AND the reported outcome is true.
    git -C "$PROJECT_ROOT" config --local core.ignorecase false
    command printf '[core]\n\tignorecase = false\n' >"$TEST_TEMP_DIR/decoy-gitconfig"

    local output
    output=$(run_fs_health_with_legacy_config "$TEST_TEMP_DIR/decoy-gitconfig" insensitive)

    assert_equals "true" "$(get_local_ignorecase)" \
        "A leaked GIT_CONFIG must not divert the repair away from the repo-local config"
    assert_contains "$output" "set core.ignorecase=true" \
        "The run should report the repair it actually made"
}

test_probe_helper_rejects_non_identifiers() {
    # The guard on run_fs_health_probe_env's argument, which is interpolated
    # into generated shell text. Untested guards are how a guard quietly stops
    # guarding, so exercise both arms.
    local status=0
    run_fs_health_probe_env 'x; rm -rf /' >/dev/null 2>&1 || status=$?
    assert_equals "1" "$status" \
        "A non-identifier variable name must be rejected, not interpolated"

    status=0
    run_fs_health_probe_env '' >/dev/null 2>&1 || status=$?
    assert_equals "1" "$status" \
        "An empty variable name must be rejected"

    # The third arm — and the one that needs care to test, because exit status
    # alone CANNOT distinguish it. Every character in "9FOO" is a legal
    # identifier character, so only the leading-digit pattern rejects it; but
    # with that pattern removed the name is accepted, interpolated, and the
    # generated stub then dies on `${9FOO-}: bad substitution`, which is also
    # non-zero. An exit-code assertion therefore passes either way (measured —
    # this test did exactly that before being rewritten).
    #
    # So assert on the guard's own DIAGNOSTIC, which only the guard emits.
    local err
    err=$(run_fs_health_probe_env '9FOO' 2>&1 >/dev/null)
    assert_contains "$err" "not a shell identifier" \
        "A digit-leading name must be rejected BY THE GUARD, not by a later bad substitution"

    # And the accepting arm still works, so the guard is not simply refusing
    # everything.
    local seen
    seen=$(GIT_CONFIG_NOSYSTEM=1 run_fs_health_probe_env GIT_CONFIG_NOSYSTEM)
    assert_equals "1" "$seen" \
        "A valid identifier must still be probed"
}

test_nosystem_optout_is_preserved() {
    # GIT_CONFIG_NOSYSTEM is deliberately NOT cleared: it is an opt-OUT (git
    # reads /etc/gitconfig by default; NOSYSTEM disables that), so unsetting it
    # would re-enable a config source a caller turned off — the opposite of what
    # this block is for. Pin that it survives, so a future "tidy up the family"
    # edit that adds it to the unset fails here instead of silently widening the
    # script's config surface.
    local seen
    seen=$(GIT_CONFIG_NOSYSTEM=1 run_fs_health_probe_env GIT_CONFIG_NOSYSTEM)

    assert_equals "1" "$seen" \
        "GIT_CONFIG_NOSYSTEM must survive the unset — it is an opt-out, not a redirect"
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
# Workspace-wide discovery tests (issue #828)
# ============================================================================
# The script used to inspect exactly one root resolved from $PWD (the build-time
# WORKING_DIR), and to treat "not a repo there" as a reason to remove the cron
# snapshot and exit 0 — killing both legs for the life of the container while
# every other repo under /workspace went unscanned. These cover the two scopes
# and the reporting that makes an empty workspace distinguishable from a healthy
# one.

# A workspace holding two repos plus two directories that are not repos, so
# every assertion below distinguishes "found the repos" from "walked everything".
# Returns the workspace root via the WS_ROOT global.
seed_workspace() {
    WS_ROOT="$TEST_TEMP_DIR/ws"
    command mkdir -p "$WS_ROOT/plain-dir"
    make_repo "$WS_ROOT/repo-a"
    make_repo "$WS_ROOT/repo-b"

    # A directory that cannot be read at all. Discovery must skip it silently
    # rather than erroring — the run is unattended and must never be fatal.
    command mkdir -p "$WS_ROOT/unreadable"
    command chmod 000 "$WS_ROOT/unreadable"
}

# chmod the unreadable fixture back so teardown's rm -rf can remove it.
unseed_workspace() {
    [ -n "${WS_ROOT:-}" ] || return 0
    command chmod 755 "$WS_ROOT/unreadable" 2>/dev/null || true
}

test_workspace_scan_repairs_every_repo() {
    # THE ISSUE: with WORKING_DIR naming a non-repo, sibling repos that were
    # mounted, decayed, and never looked at.
    seed_workspace
    run_fs_health_workspace "$WS_ROOT" insensitive >/dev/null

    assert_equals "true" "$(get_ignorecase_at "$WS_ROOT/repo-a")" \
        "Workspace scan should repair the first discovered repo"
    assert_equals "true" "$(get_ignorecase_at "$WS_ROOT/repo-b")" \
        "Workspace scan should repair every discovered repo, not just one"
    unseed_workspace
}

test_workspace_scan_reports_repo_paths() {
    # Per-repo reporting: with several roots in play, a finding is only
    # actionable if the line names which repo it came from.
    seed_workspace
    local output
    output=$(run_fs_health_workspace "$WS_ROOT" insensitive)

    assert_contains "$output" "$WS_ROOT/repo-a" \
        "Report should name the repo each finding came from"
    assert_contains "$output" "$WS_ROOT/repo-b" \
        "Report should name every repaired repo"
    unseed_workspace
}

test_workspace_scan_skips_non_repos() {
    # A workspace legitimately holds non-repo directories and unreadable ones.
    # Neither is an error, and neither should produce output.
    seed_workspace
    local output
    output=$(run_fs_health_workspace "$WS_ROOT" insensitive)

    assert_not_contains "$output" "plain-dir" \
        "A non-repo directory should be skipped without comment"
    assert_not_contains "$output" "unreadable" \
        "An unreadable directory should be skipped without error"
    unseed_workspace
}

test_workspace_root_itself_scanned_when_a_repo() {
    # A single repo mounted directly AT the workspace root. Skipping it would
    # regress against the old $PWD behavior instead of fixing it.
    local ws="$TEST_TEMP_DIR/ws-is-repo"
    make_repo "$ws"

    run_fs_health_workspace "$ws" insensitive >/dev/null

    assert_equals "true" "$(get_ignorecase_at "$ws")" \
        "A repo mounted at the workspace root itself should be scanned"
}

test_workspace_scan_reports_zero_repos() {
    # The silent-exit defect itself: "nothing to inspect" and "everything is
    # healthy" were the same observable, which is how a container repaired
    # nothing for its whole life without anyone noticing.
    local ws="$TEST_TEMP_DIR/empty-ws"
    command mkdir -p "$ws"

    local output
    output=$(run_fs_health_workspace "$ws" insensitive)

    assert_contains "$output" "no git repositories found" \
        "An empty workspace should be reported, not silently skipped"
}

test_workspace_scan_reports_missing_root() {
    local output
    output=$(run_fs_health_workspace "$TEST_TEMP_DIR/no-such-workspace" insensitive)

    assert_contains "$output" "does not exist" \
        "A missing workspace root should be reported distinctly from an empty one"
}

test_zero_repos_still_writes_snapshot() {
    # THE COMPOUNDING HALF of the bug. Removing the snapshot here is what
    # disabled the hourly leg permanently; keeping it is what lets a repo
    # mounted an hour later still get repaired.
    local ws="$TEST_TEMP_DIR/empty-ws-snap"
    command mkdir -p "$ws"

    run_fs_health_workspace "$ws" insensitive >/dev/null

    assert_file_exists "$FS_HEALTH_ENV_FILE" \
        "A workspace with zero repos should still arm the hourly leg"
    assert_equals "$ws" "$(get_snapshot_value WORKSPACE_ROOT)" \
        "Snapshot should record the workspace root to re-discover under"
}

test_workspace_snapshot_records_empty_project_root() {
    # The empty PROJECT_ROOT is meaningful, not missing: it is what tells the
    # cron leg to re-discover rather than repair one fixed path.
    seed_workspace
    run_fs_health_workspace "$WS_ROOT" sensitive >/dev/null

    assert_equals "" "$(get_snapshot_value PROJECT_ROOT)" \
        "A workspace-scope run should record an empty PROJECT_ROOT"
    assert_equals "$WS_ROOT" "$(get_snapshot_value WORKSPACE_ROOT)" \
        "A workspace-scope run should record the workspace root"
    unseed_workspace
}

test_explicit_project_root_restricts_scan() {
    # The on-demand contract: naming a root must inspect THAT repo only, even
    # though a sibling repo sits right beside it under the same workspace root.
    seed_workspace

    (
        export PROJECT_ROOT="$WS_ROOT/repo-a"
        export WORKSPACE_ROOT="$WS_ROOT"
        export FS_CASE_STATE=insensitive
        export FS_HEALTH_ENV_FILE
        bash "$FS_HEALTH_SCRIPT"
    ) >/dev/null 2>&1

    assert_equals "true" "$(get_ignorecase_at "$WS_ROOT/repo-a")" \
        "An explicit PROJECT_ROOT should still repair the repo it names"
    assert_equals "unset" "$(get_ignorecase_at "$WS_ROOT/repo-b")" \
        "An explicit PROJECT_ROOT must NOT widen into a workspace-wide scan"
    unseed_workspace
}

test_case_detection_runs_per_repo() {
    # Different mounts can genuinely differ in case-sensitivity, so the verdict
    # must be sampled per repo rather than once for the whole workspace.
    #
    # Drives it through a STUB detector that answers "insensitive" for repo-a
    # and "sensitive" for repo-b: a single shared verdict cannot produce this
    # split, so the assertion pair fails if detection is hoisted back out of the
    # loop. FS_CASE_STATE is left unset here on purpose — forcing it is what
    # every other test does, and it bypasses detection entirely.
    seed_workspace

    local detector="$TEST_TEMP_DIR/detect-case.sh"
    command cat >"$detector" <<'DETECT_EOF'
#!/bin/bash
# Exit 1 (insensitive) for repo-a, 0 (sensitive) for anything else.
case "$1" in
    *repo-a*) exit 1 ;;
    *) exit 0 ;;
esac
DETECT_EOF
    command chmod +x "$detector"

    (
        unset PROJECT_ROOT FS_CASE_STATE 2>/dev/null || true
        export WORKSPACE_ROOT="$WS_ROOT"
        export CASE_DETECT_SCRIPT="$detector"
        export FS_HEALTH_ENV_FILE
        bash "$FS_HEALTH_SCRIPT"
    ) >/dev/null 2>&1

    assert_equals "true" "$(get_ignorecase_at "$WS_ROOT/repo-a")" \
        "The repo the detector called insensitive should be repaired"
    assert_equals "unset" "$(get_ignorecase_at "$WS_ROOT/repo-b")" \
        "A repo the detector called sensitive must not inherit a sibling's verdict"
    unseed_workspace
}

test_workspace_scan_does_not_double_scan_nested_worktree() {
    # Depth-1 discovery and the in-repo worktree walk can name the SAME
    # directory: when the workspace root is itself a repo, a linked worktree
    # beside it at depth 1 has a .git FILE — exactly the shape discovery accepts.
    # It must be repaired once, by the root that owns it.
    #
    # The duplicate was not merely noisy: the second pass reported the path with
    # no label prefix, so one file produced two lines that read as two files.
    local ws="$TEST_TEMP_DIR/ws-nested"
    make_repo "$ws"
    echo "content" >"$ws/target.txt"
    command ln -s target.txt "$ws/AGENTS.md"
    git -C "$ws" add -A >/dev/null 2>&1
    git -C "$ws" commit -qm "seed" >/dev/null 2>&1
    git -C "$ws" worktree add -q "$ws/wt" -b wt-branch >/dev/null 2>&1

    local output
    output=$(FS_HEALTH_STAT="$(stale_stat_stub AGENTS.md)" \
        run_fs_health_workspace "$ws" sensitive)

    # Once from the owning repo, once from its worktree — two files, two repairs.
    assert_equals "2" "$(command printf '%s\n' "$output" | /usr/bin/grep -c 'refreshed')" \
        "A worktree at depth 1 of a repo workspace root should be repaired exactly once"
}

test_workspace_scan_does_not_double_scan_submodule() {
    # Same shape as the worktree case, via the other walk: an initialized
    # submodule's .git is also a FILE, so depth-1 discovery would re-emit it.
    local ws="$TEST_TEMP_DIR/ws-sub"
    local upstream="$TEST_TEMP_DIR/upstream"
    make_repo "$upstream"
    echo "content" >"$upstream/target.txt"
    command ln -s target.txt "$upstream/AGENTS.md"
    git -C "$upstream" add -A >/dev/null 2>&1
    git -C "$upstream" commit -qm "seed" >/dev/null 2>&1

    make_repo "$ws"
    echo "root" >"$ws/root.txt"
    git -C "$ws" add -A >/dev/null 2>&1
    git -C "$ws" commit -qm "seed" >/dev/null 2>&1
    git -C "$ws" -c protocol.file.allow=always submodule add -q "$upstream" sub >/dev/null 2>&1
    git -C "$ws" commit -qm "add sub" >/dev/null 2>&1

    local output
    output=$(FS_HEALTH_STAT="$(stale_stat_stub AGENTS.md)" \
        run_fs_health_workspace "$ws" sensitive)

    assert_equals "1" "$(command printf '%s\n' "$output" | /usr/bin/grep -c 'refreshed')" \
        "A submodule at depth 1 of a repo workspace root should be repaired exactly once"
    assert_contains "$output" "sub/AGENTS.md" \
        "The submodule repair should keep its submodule label, not be re-reported bare"
}

test_workspace_scan_dedups_sibling_worktree_either_order() {
    # A worktree that is a SIBLING of its owning repo — `git worktree add
    # /workspace/repo-wt` when the repo is /workspace/repo — is a depth-1 entry
    # in its own right, so discovery can reach it BEFORE the repo that owns it.
    #
    # That order is decided by readdir, not by anything the script controls, so
    # a one-directional ledger (claim-only, no seen-check in the walks) left the
    # duplicate to chance: the worktree was repaired once bare as an independent
    # root, then again labeled by its owner. Build the dirent order that exposes
    # it — worktree created in the workspace first, owning repo added after.
    local ws="$TEST_TEMP_DIR/ws-sibling"
    local src="$TEST_TEMP_DIR/sibling-src"
    make_repo "$src"
    echo "content" >"$src/target.txt"
    command ln -s target.txt "$src/AGENTS.md"
    git -C "$src" add -A >/dev/null 2>&1
    git -C "$src" commit -qm "seed" >/dev/null 2>&1

    command mkdir -p "$ws"
    git -C "$src" worktree add -q "$ws/wt" -b sibling-branch >/dev/null 2>&1
    # Copy (not move) the owning repo in AFTER the worktree's dirent exists, so
    # it is enumerated second while still owning that worktree.
    command cp -a "$src" "$ws/repo"

    local output
    output=$(FS_HEALTH_STAT="$(stale_stat_stub AGENTS.md)" \
        run_fs_health_workspace "$ws" sensitive)

    assert_equals "1" "$(command printf '%s\n' "$output" | /usr/bin/grep -c 'refreshed .*/wt/AGENTS.md')" \
        "A sibling worktree must be repaired once even when discovery reaches it before its owner"
}

test_workspace_symlink_report_names_the_repo() {
    # ACCEPTANCE CRITERION: "a repo whose stale symlinks are repaired is reported
    # per-repo, with the repo path in the log line."
    #
    # check_ignorecase already prints an absolute root, so this pins the OTHER
    # repair. Both repos get a symlink at the SAME relative path — the realistic
    # case (every repo has an AGENTS.md), and the one where a bare relative path
    # names one file while reading as either.
    seed_workspace
    local repo
    for repo in "$WS_ROOT/repo-a" "$WS_ROOT/repo-b"; do
        echo "content" >"$repo/target.txt"
        command ln -s target.txt "$repo/AGENTS.md"
        git -C "$repo" add -A >/dev/null 2>&1
        git -C "$repo" commit -qm "seed" >/dev/null 2>&1
    done

    local output
    output=$(FS_HEALTH_STAT="$(stale_stat_stub AGENTS.md)" \
        run_fs_health_workspace "$WS_ROOT" sensitive)

    assert_contains "$output" "$WS_ROOT/repo-a/AGENTS.md" \
        "A stale-symlink repair should name the repo it happened in"
    assert_contains "$output" "$WS_ROOT/repo-b/AGENTS.md" \
        "Two repos sharing a relative path must be distinguishable in the log"
    unseed_workspace
}

test_single_scope_symlink_report_stays_relative() {
    # The per-repo prefix is a WORKSPACE-scope concern. With one repo named
    # explicitly there is nothing to disambiguate, and the established output is
    # the repo-relative path — prefixing it would churn the on-demand command's
    # output for no gain.
    seed_symlinks
    command ln -s realfile.txt "$PROJECT_ROOT/AGENTS.md"
    git -C "$PROJECT_ROOT" add -A >/dev/null 2>&1
    git -C "$PROJECT_ROOT" commit -qm "agents link" >/dev/null 2>&1

    local output
    output=$(FS_HEALTH_STAT="$(stale_stat_stub AGENTS.md)" \
        run_fs_health_stderr sensitive)

    assert_contains "$output" "refreshed AGENTS.md" \
        "Single scope should keep the repo-relative form"
    assert_not_contains "$output" "refreshed $PROJECT_ROOT/AGENTS.md" \
        "Single scope should not gain a redundant absolute prefix"
}

test_exported_empty_project_root_stays_single_scope() {
    # The scope check reads ${PROJECT_ROOT+x} (SET, including empty) rather than
    # ${PROJECT_ROOT:-} (set AND non-empty), deliberately: an exported-but-empty
    # PROJECT_ROOT is a caller mistake, and pinning single scope on the empty
    # path surfaces it. Treating it as unset would instead silently scan the
    # whole workspace — writing to repos the caller never named.
    #
    # Without this test, "simplifying" +x back to :- would pass every other
    # test in the suite.
    seed_workspace

    (
        export PROJECT_ROOT=""
        export WORKSPACE_ROOT="$WS_ROOT"
        export FS_CASE_STATE=insensitive
        export FS_HEALTH_ENV_FILE
        bash "$FS_HEALTH_SCRIPT"
    ) >/dev/null 2>&1

    assert_equals "unset" "$(get_ignorecase_at "$WS_ROOT/repo-a")" \
        "An exported-but-empty PROJECT_ROOT must not widen into a workspace scan"
    assert_equals "unset" "$(get_ignorecase_at "$WS_ROOT/repo-b")" \
        "No repo under the workspace should be touched on the empty-path branch"
    assert_file_not_exists "$FS_HEALTH_ENV_FILE" \
        "The empty path is not a repo, so the run should clear the snapshot"
    unseed_workspace
}

test_workspace_skip_case_check_removes_snapshot() {
    # The opt-out must still disable BOTH legs under the new default scope.
    local ws="$TEST_TEMP_DIR/ws-optout"
    make_repo "$ws/repo-a"

    run_fs_health_workspace "$ws" sensitive >/dev/null
    assert_file_exists "$FS_HEALTH_ENV_FILE" "Precondition: snapshot exists"

    export SKIP_CASE_CHECK=true
    run_fs_health_workspace "$ws" sensitive >/dev/null

    assert_file_not_exists "$FS_HEALTH_ENV_FILE" \
        "SKIP_CASE_CHECK=true should still remove the snapshot in workspace scope"
}

test_cron_wrapper_rediscovers_from_workspace_root() {
    # The payoff of recording the ROOT rather than the discovered repo list: a
    # repo mounted into a running container is repaired by the next hourly pass,
    # without waiting for a restart.
    local ws="$TEST_TEMP_DIR/ws-late"
    command mkdir -p "$ws"

    # Boot run against an empty workspace — arms the leg, repairs nothing.
    run_fs_health_workspace "$ws" sensitive >/dev/null
    assert_file_exists "$FS_HEALTH_ENV_FILE" "Precondition: snapshot armed"

    # A repo appears afterwards.
    make_repo "$ws/repo-late"

    run_cron_wrapper insensitive >/dev/null

    assert_equals "true" "$(get_ignorecase_at "$ws/repo-late")" \
        "The cron leg should re-discover and repair a repo mounted after boot"
}

test_cron_wrapper_honors_single_scope_snapshot() {
    # Back-compat: a snapshot written by an OLDER image carries only a non-empty
    # PROJECT_ROOT and no WORKSPACE_ROOT line. The cron leg must keep honoring
    # it as single scope, so an upgrade-in-place does not break the hourly leg
    # until the next boot rewrites the snapshot.
    command printf "%s\n" \
        "PROJECT_ROOT='$PROJECT_ROOT'" \
        "SKIP_CASE_FIX='false'" \
        >"$FS_HEALTH_ENV_FILE"

    run_cron_wrapper insensitive >/dev/null

    assert_equals "true" "$(get_ignorecase)" \
        "A legacy PROJECT_ROOT-only snapshot should still drive a single-repo repair"
}

test_cron_wrapper_noop_on_snapshot_with_neither_root() {
    # Malformed is now "names NEITHER root" — still never a fallback to cron's
    # $PWD, which is the user's home.
    command printf "%s\n" "SKIP_CASE_FIX='false'" >"$FS_HEALTH_ENV_FILE"

    local output
    output=$(run_cron_wrapper insensitive)
    assert_empty "$output" \
        "Cron wrapper should no-op on a snapshot naming neither root"
}

test_ondemand_no_arg_stays_single_scope() {
    # `workspace-fs-health` with no argument documents "the current directory's
    # project". The script's default scope is now the whole workspace, so the
    # wrapper has to pin $PWD explicitly — without that this silently becomes a
    # workspace-wide scan.
    seed_workspace

    (
        cd "$WS_ROOT/repo-a" || exit 1
        unset PROJECT_ROOT 2>/dev/null || true
        export WORKSPACE_ROOT="$WS_ROOT"
        export FS_HEALTH_SCRIPT="$FS_HEALTH_SCRIPT"
        export FS_HEALTH_ENV_FILE
        export FS_CASE_STATE=insensitive
        bash "$ONDEMAND_WRAPPER"
    ) >/dev/null 2>&1

    assert_equals "true" "$(get_ignorecase_at "$WS_ROOT/repo-a")" \
        "A bare on-demand run should repair the current directory's project"
    assert_equals "unset" "$(get_ignorecase_at "$WS_ROOT/repo-b")" \
        "A bare on-demand run must not widen into a workspace-wide scan"
    unseed_workspace
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

run_test_with_setup test_skip_when_case_check_disabled "Skip when SKIP_CASE_CHECK=true"
run_test_with_setup test_skip_when_not_a_git_repo "Skip when not a git repository"
run_test_with_setup test_worktree_git_file_accepted "Accepts a worktree .git file"
run_test_with_setup test_sets_ignorecase_when_insensitive "Sets core.ignorecase on case-insensitive FS"
run_test_with_setup test_leaves_ignorecase_when_sensitive "Leaves core.ignorecase on case-sensitive FS"
run_test_with_setup test_no_change_when_detection_unknown "No change when detection is inconclusive"
run_test_with_setup test_corrects_explicit_false "Corrects an explicit core.ignorecase=false"
run_test_with_setup test_idempotent_when_already_true "Idempotent when core.ignorecase already true"
run_test_with_setup test_skip_fix_reports_without_writing "SKIP_CASE_FIX reports without writing"
run_test_with_setup test_config_count_injection_does_not_suppress_repair "Injected GIT_CONFIG_COUNT does not suppress the ignorecase repair"
run_test_with_setup test_config_global_injection_does_not_suppress_repair "Substituted GIT_CONFIG_GLOBAL does not suppress the ignorecase repair"
run_test_with_setup test_config_parameters_injection_does_not_suppress_repair "Injected GIT_CONFIG_PARAMETERS does not mask a wrong local value"
run_test_with_setup test_legacy_git_config_does_not_divert_the_write "Leaked legacy GIT_CONFIG does not divert the repair write"
run_test_with_setup test_probe_helper_rejects_non_identifiers "Probe helper rejects non-identifier variable names"
run_test_with_setup test_nosystem_optout_is_preserved "GIT_CONFIG_NOSYSTEM opt-out survives the unset"
run_test_with_setup test_silent_when_healthy "Silent when filesystem is healthy"
run_test_with_setup test_reports_when_repairing "Reports the setting it changed"
run_test_with_setup test_healthy_symlink_untouched "Healthy symlink left untouched"
run_test_with_setup test_broken_symlink_untouched "Broken symlink left untouched"
run_test_with_setup test_directory_symlink_not_polluted "Directory symlink not polluted"
run_test_with_setup test_symlinks_leave_repo_clean "Repo stays clean after symlink pass"
run_test_with_setup test_silent_with_healthy_symlinks_present "Silent when all symlinks are healthy"
run_test_with_setup test_regular_files_untouched "Regular files untouched"
run_test_with_setup test_workspace_scan_repairs_every_repo "Workspace scan repairs every discovered repo"
run_test_with_setup test_workspace_scan_reports_repo_paths "Workspace scan names each repo it repairs"
run_test_with_setup test_workspace_scan_skips_non_repos "Workspace scan skips non-repo and unreadable dirs"
run_test_with_setup test_workspace_root_itself_scanned_when_a_repo "Workspace root itself is scanned when it is a repo"
run_test_with_setup test_workspace_scan_reports_zero_repos "Zero repos under the workspace is reported"
run_test_with_setup test_workspace_scan_reports_missing_root "A missing workspace root is reported distinctly"
run_test_with_setup test_zero_repos_still_writes_snapshot "Zero repos still arms the hourly leg"
run_test_with_setup test_workspace_snapshot_records_empty_project_root "Workspace scope records an empty PROJECT_ROOT"
run_test_with_setup test_explicit_project_root_restricts_scan "Explicit PROJECT_ROOT restricts the scan to one repo"
run_test_with_setup test_case_detection_runs_per_repo "Case detection runs per repo"
run_test_with_setup test_exported_empty_project_root_stays_single_scope "Exported-but-empty PROJECT_ROOT stays single-scope"
run_test_with_setup test_workspace_scan_does_not_double_scan_nested_worktree "A nested worktree is scanned once, not twice"
run_test_with_setup test_workspace_scan_does_not_double_scan_submodule "A nested submodule is scanned once, not twice"
run_test_with_setup test_workspace_scan_dedups_sibling_worktree_either_order "A sibling worktree is deduped regardless of discovery order"
run_test_with_setup test_workspace_symlink_report_names_the_repo "Symlink repairs name their repo in workspace scope"
run_test_with_setup test_single_scope_symlink_report_stays_relative "Single scope keeps the repo-relative symlink form"
run_test_with_setup test_workspace_skip_case_check_removes_snapshot "SKIP_CASE_CHECK removes the snapshot in workspace scope"
run_test_with_setup test_cron_wrapper_rediscovers_from_workspace_root "Cron leg re-discovers a repo mounted after boot"
run_test_with_setup test_cron_wrapper_honors_single_scope_snapshot "Cron leg honors a legacy PROJECT_ROOT-only snapshot"
run_test_with_setup test_cron_wrapper_noop_on_snapshot_with_neither_root "Cron leg no-ops on a snapshot naming neither root"
run_test_with_setup test_ondemand_no_arg_stays_single_scope "Bare on-demand run stays single-scope"
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
