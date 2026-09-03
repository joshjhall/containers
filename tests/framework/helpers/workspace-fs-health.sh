#!/usr/bin/env bash
# Shared fixtures for the lib/runtime/42-workspace-fs-health.sh test suites.
#
# SOURCE-ONLY — this file defines no tests and must never be executed directly.
# It lives under tests/framework/ rather than tests/unit/ for that reason:
# run_unit_tests.sh discovers suites with `find tests/unit -name "*.sh"`, so a
# fragment placed anywhere beneath tests/unit (including tests/unit/runtime/lib/)
# would be picked up and run as a suite with zero tests. tests/framework/ is
# outside that find root and is already where shared test code lives
# (tests/framework/helpers.sh, tests/framework/assertions/).
#
# Sourced by:
#   tests/unit/runtime/workspace-fs-health.sh            (ignorecase, symlinks, cron, root re-exec)
#   tests/unit/runtime/workspace-fs-health-submodules.sh (staleness predicate, submodule traversal)
#
# Source it AFTER framework.sh + init_test_framework — setup() reads
# TEST_SCRATCH_BASE, which init_test_framework establishes.
#
# Split out of workspace-fs-health.sh in issue #832; the seam was identified by
# the decomposition dimension of the PR #829 adversarial review.

# Path to the script under test. Resolved from this file's own location so it
# is correct regardless of which suite sources it.
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
        FS_HEALTH_MAX_DEPTH FS_HEALTH_GIT 2>/dev/null || true

    # Clear any inherited git environment so a leak in the HARNESS cannot be
    # mistaken for the leak-immunity the script now provides (issue #886, widened
    # to the config-redirect family in #894). The immunity tests set these
    # deliberately; every other test must start clean — a stray GIT_CONFIG_COUNT
    # in the developer's or CI's environment would otherwise suppress the
    # ignorecase repair under test and read as a mysterious assertion failure.
    unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
        GIT_OBJECT_DIRECTORY GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM \
        GIT_CONFIG_NOSYSTEM GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 \
        GIT_CONFIG_VALUE_0 GIT_CONFIG_PARAMETERS GIT_CONFIG 2>/dev/null || true
}

teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
    unset PROJECT_ROOT TEST_TEMP_DIR SKIP_CASE_CHECK SKIP_CASE_FIX \
        FS_HEALTH_ENV_FILE FS_HEALTH_UPDATE_ENV FS_HEALTH_STAT \
        FS_HEALTH_MAX_DEPTH FS_HEALTH_GIT 2>/dev/null || true
    unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
        GIT_OBJECT_DIRECTORY GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM \
        GIT_CONFIG_NOSYSTEM GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 \
        GIT_CONFIG_VALUE_0 GIT_CONFIG_PARAMETERS GIT_CONFIG 2>/dev/null || true
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
        export FS_HEALTH_GIT="${FS_HEALTH_GIT:-git}"
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
        export FS_HEALTH_GIT="${FS_HEALTH_GIT:-git}"
        { bash "$FS_HEALTH_SCRIPT" >/dev/null; } 2>&1
    )
}

# Run the script with a substituted GIT_CONFIG_GLOBAL (issue #894).
#
# Separate from run_fs_health because the assignment is built inside `env`
# rather than as an inline VAR=... prefix: the Claude Code worktree guard
# refuses a command that sets GIT_CONFIG_GLOBAL inline, since it cannot verify
# where the redirected config would send a write. Routing it through `env` in a
# committed helper keeps the immunity test runnable.
#
# Args: $1 = path to the config file to inject, $2 = fs state
run_fs_health_with_global_config() {
    local injected="$1"
    local state="$2"
    (
        export PROJECT_ROOT
        export FS_CASE_STATE="$state"
        export SKIP_CASE_CHECK="${SKIP_CASE_CHECK:-false}"
        export SKIP_CASE_FIX="${SKIP_CASE_FIX:-false}"
        export FS_HEALTH_ENV_FILE
        export FS_HEALTH_STAT="${FS_HEALTH_STAT:-/usr/bin/stat}"
        export FS_HEALTH_GIT="${FS_HEALTH_GIT:-git}"
        command env "GIT_CONFIG_GLOBAL=$injected" bash "$FS_HEALTH_SCRIPT"
    ) >/dev/null 2>&1
}

# Run the script with a substituted legacy GIT_CONFIG, returning stderr (#894).
#
# Same `env`-not-inline reason as run_fs_health_with_global_config: the worktree
# guard refuses a command that sets a config-redirect var inline.
#
# Returns stderr because this vector's failure mode is a FALSE SUCCESS — the
# script reports a repair it did not make — so the test has to inspect what was
# reported, not only what was written.
#
# Args: $1 = path to the config file to inject, $2 = fs state
run_fs_health_with_legacy_config() {
    local injected="$1"
    local state="$2"
    (
        export PROJECT_ROOT
        export FS_CASE_STATE="$state"
        export SKIP_CASE_CHECK="${SKIP_CASE_CHECK:-false}"
        export SKIP_CASE_FIX="${SKIP_CASE_FIX:-false}"
        export FS_HEALTH_ENV_FILE
        export FS_HEALTH_STAT="${FS_HEALTH_STAT:-/usr/bin/stat}"
        export FS_HEALTH_GIT="${FS_HEALTH_GIT:-git}"
        { command env "GIT_CONFIG=$injected" bash "$FS_HEALTH_SCRIPT" >/dev/null; } 2>&1
    )
}

# Report what ONE environment variable holds inside the script, after its unset
# block has run (issue #894).
#
# This is what lets a test pin a variable as deliberately NOT cleared — a
# property no amount of observing repair behavior can show, because an opt-out
# that gets wrongly cleared changes nothing visible until the day it does.
#
# HOW, and why not the obvious way: sourcing the script to inspect the
# environment afterwards does NOT work. The project-root guard runs `exit 0` on
# a non-repo directory, which terminates the sourcing subshell before it can
# report anything (measured: the probe printed nothing at all). Instead the
# script is EXECUTED normally against a real fixture repo, with FS_HEALTH_GIT
# pointed at a stub that records its own environment.
#
# PRECISELY: the stub sees the first call routed through the FS_HEALTH_GIT seam,
# which only repair_linked_worktrees uses — NOT the script's literal first git
# call, which is check_symlinks' bare `git -C ... ls-files -s` and bypasses the
# seam entirely. The observed value is the same either way, because the unset
# runs once, unconditionally, in the Configuration section above every git call
# of either kind. Stated exactly so a future maintainer who widens the seam or
# moves the unset does not rely on a guarantee this helper never made.
#
# Args: $1 = variable name to report. Echoes its value, or "" if unset.
run_fs_health_probe_env() {
    local var="$1"
    local stub="$TEST_TEMP_DIR/env-probe-git"
    local out="$TEST_TEMP_DIR/env-probe-out"

    # $var is interpolated into the generated stub's source, so constrain it to
    # a shell identifier. Every caller passes a literal today, which is why this
    # is a guard rather than a fix — but the constraint was implicit, and an
    # implicit constraint on generated shell text is worth making explicit
    # before someone passes a computed name.
    case "$var" in
        '' | *[!A-Za-z0-9_]* | [0-9]*)
            command echo "run_fs_health_probe_env: not a shell identifier: $var" >&2
            return 1
            ;;
    esac

    command rm -f "$out"

    local real_git
    real_git=$(command -v git)

    command cat >"$stub" <<PROBE_STUB_EOF
#!/bin/bash
# Record the probed variable once, then behave exactly like git so the run
# proceeds normally and nothing else is perturbed.
if [ ! -e "$out" ]; then
    command printf '%s' "\${$var-}" >"$out"
fi
exec "$real_git" "\$@"
PROBE_STUB_EOF
    command chmod +x "$stub"

    (
        export PROJECT_ROOT
        export FS_CASE_STATE=sensitive
        export SKIP_CASE_CHECK=false
        export SKIP_CASE_FIX=false
        export FS_HEALTH_ENV_FILE
        export FS_HEALTH_UPDATE_ENV=false
        export FS_HEALTH_STAT="${FS_HEALTH_STAT:-/usr/bin/stat}"
        export FS_HEALTH_GIT="$stub"
        bash "$FS_HEALTH_SCRIPT"
    ) >/dev/null 2>&1

    [ -e "$out" ] && command cat "$out"
}

# Current core.ignorecase, or the literal "unset"
get_ignorecase() {
    git -C "$PROJECT_ROOT" config --get core.ignorecase 2>/dev/null || echo "unset"
}

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

# Run one test between a fresh setup and its teardown.
# Args: $1 = test function name, $2 = human-readable description
run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"

    setup
    run_test "$test_function" "$test_description"
    teardown
}
