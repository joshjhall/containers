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
    # mistaken for the leak-immunity the script now provides (issue #886). The
    # AC1 test sets GIT_DIR deliberately; every other test must start clean.
    unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
        GIT_OBJECT_DIRECTORY 2>/dev/null || true
}

teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
    unset PROJECT_ROOT TEST_TEMP_DIR SKIP_CASE_CHECK SKIP_CASE_FIX \
        FS_HEALTH_ENV_FILE FS_HEALTH_UPDATE_ENV FS_HEALTH_STAT \
        FS_HEALTH_MAX_DEPTH FS_HEALTH_GIT 2>/dev/null || true
    unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
        GIT_OBJECT_DIRECTORY 2>/dev/null || true
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
