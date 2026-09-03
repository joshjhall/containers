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
