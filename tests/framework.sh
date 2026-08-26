#!/usr/bin/env bash
# Test Framework for Container Build System
# Version: 4.19.26
# Test framework for container build system
#
# Provides comprehensive assertion-based testing for container builds.
# All test framework variables and internal functions use the tf_ prefix
# to avoid namespace collisions with code under test.
#
# Key Features:
# - Comprehensive assertion library (equality, strings, files, etc.)
# - Docker-specific assertions for container testing
# - Automatic setup/teardown for each test
# - Test report generation with pass/fail statistics
# - Color output support (when terminal supports it)
# - Safe implementation (no eval statements)
#
# Dependencies:
# - framework/helpers.sh (loaded automatically)
# - Docker installed and running
# - Bash 4.0+
#
# Usage:
#   source framework.sh
#   init_test_framework
#   test_suite "My Test Suite"
#   run_test my_test_function "test description"
#   generate_report
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed

set -euo pipefail

# Clear inherited git environment so fixture-building tests are hermetic.
#
# git exports GIT_DIR / GIT_INDEX_FILE / GIT_WORK_TREE / GIT_COMMON_DIR /
# GIT_PREFIX into the environment of any hook it spawns (e.g. lefthook
# pre-push). A test that builds a throwaway repo with `git init` /
# `git worktree add` in a mktemp dir would otherwise have those nested git
# commands hijacked back at the REAL repository — fixtures silently fail to
# build, assertions diverge from the standalone run, and stray commits can land
# on the live branch. Clearing them here at module scope — before the sub-module
# `source` calls below — protects the framework bootstrap too, not just the test
# bodies, so the guard holds even if a sourced module ever calls git at module
# scope. init_test_framework re-clears as belt-and-suspenders. See #599 / #587.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR GIT_PREFIX

# Framework version (exported for external use)
# shellcheck disable=SC2034  # Used by external scripts
readonly TEST_FRAMEWORK_VERSION="4.19.26"

# Initialize test directories
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINERS_DIR="$(dirname "$TESTS_DIR")"

# Source framework components
source "$TESTS_DIR/framework/helpers.sh"

# Source all assertion modules
source "$TESTS_DIR/framework/assertions/core.sh"
source "$TESTS_DIR/framework/assertions/equality.sh"
source "$TESTS_DIR/framework/assertions/string.sh"
source "$TESTS_DIR/framework/assertions/numeric.sh"
source "$TESTS_DIR/framework/assertions/file.sh"
source "$TESTS_DIR/framework/assertions/state.sh"
source "$TESTS_DIR/framework/assertions/exit_code.sh"
source "$TESTS_DIR/framework/assertions/docker.sh"

# Test framework configuration
# shellcheck disable=SC2034  # Used by test files
PROJECT_ROOT="$CONTAINERS_DIR"
RESULTS_DIR="$TESTS_DIR/results"
FIXTURES_DIR="$TESTS_DIR/fixtures"

# Filesystems where a write is not reliably visible to an immediately-following
# open() in the same process. The first four names mirror the permission-faking
# list in lib/runtime/lib/setup-bindfs.sh; the rest cover the wider FUSE and
# network-filesystem families. See tf_scratch_root below for why this matters.
readonly TF_INCOHERENT_FSTYPES_RE='^(fuse|fuse\..*|fuseblk|fakeowner|virtiofs|grpcfuse|osxfs|9p|nfs|nfs[0-9]+|cifs|smbfs)$'

# Report the filesystem type backing a path, or empty when it cannot be probed.
# Absolute paths per CLAUDE.md — an alias must not be able to change the answer.
tf_fstype_of() {
    local tff_path="$1"
    if command -v findmnt >/dev/null 2>&1; then
        /usr/bin/findmnt -no FSTYPE -T "$tff_path" 2>/dev/null && return 0
    fi
    /usr/bin/stat -f -c %T "$tff_path" 2>/dev/null || true
}

# True when a path sits on a filesystem from the deny list above.
tf_is_incoherent_fs() {
    local tfi_fstype
    tfi_fstype=$(tf_fstype_of "$1")
    # An unprobeable filesystem is treated as acceptable: a probe failure must
    # never hard-fail a developer's test run. The regression suite
    # (tests/unit/test_framework_scratch_base.sh) is what turns a genuinely bad
    # location into a red run.
    [ -n "$tfi_fstype" ] && command printf '%s' "$tfi_fstype" |
        command grep -qE "$TF_INCOHERENT_FSTYPES_RE"
}

# Pick the first candidate tmp root that is NOT on an incoherence-prone
# filesystem. Falls back to /tmp so the framework always has somewhere to work.
tf_scratch_root() {
    local tfs_candidate
    for tfs_candidate in "${TMPDIR:-}" /tmp /dev/shm; do
        [ -n "$tfs_candidate" ] || continue
        [ -d "$tfs_candidate" ] || continue
        if ! tf_is_incoherent_fs "$tfs_candidate"; then
            command printf '%s' "${tfs_candidate%/}"
            return 0
        fi
    done
    command printf '/tmp'
}

# Scratch space for test fixtures — deliberately OUTSIDE the repository (#821).
#
# This repo is commonly mounted through virtiofs plus a bindfs FUSE overlay. On
# that stack a write is not always visible to an immediately-following open():
# a single-process, zero-concurrency "write a file then grep it" loop misses
# ~3/400 under tests/results, and 0/400 under /tmp. Suites that kept scratch
# under the reports dir therefore reddened at random — one suite per full run,
# a different suite each time, always passing when re-run standalone. The
# per-suite unique suffixes added in #817 are orthogonal: they stop suites
# deleting each other's trees, but cannot make a write visible to the next read.
#
# So scratch lives here and $RESULTS_DIR is reserved for reports and CI
# artifacts. Keeping the base off the repo also means no new lint/gitignore
# exclusions are needed. Override TEST_SCRATCH_BASE to relocate it.
#
# Defined at module scope (like RESULTS_DIR) so suites may reference it at
# top level, and made unique per suite process so concurrent suites cannot
# collide.
# The parent is per-uid: /tmp is world-writable (1777), so a fixed shared name
# lets any other local user pre-create it and choose its initial mode/ownership
# (CWE-377). Suffixing with the uid means unrelated users cannot collide on one
# well-known path at all; it is created with an explicit 700 below.
TEST_SCRATCH_ROOT="$(tf_scratch_root)"
TEST_SCRATCH_PARENT="$TEST_SCRATCH_ROOT/container-test-scratch-$(id -u 2>/dev/null || echo 0)"
TEST_SCRATCH_BASE="${TEST_SCRATCH_BASE:-$TEST_SCRATCH_PARENT/$$-$(date +%s%N)}"

# ============================================================================
# tf_reap_stale_temp_dirs - Remove abandoned per-test scratch directories
#
# Suites create their TEST_TEMP_DIR under $TEST_SCRATCH_BASE with a per-test
# unique suffix, so two suites running concurrently cannot delete each other's
# tree. The cost of that uniqueness is that any teardown a suite misses — an
# early exit, a failed assertion that skips the rest, a killed run — leaks a NEW
# directory rather than reusing one name. Measured at ~1,400 per full run,
# growing without bound (one tree reached 19,910 directories / 11MB).
#
# So the framework reaps them centrally, at init, rather than relying on every
# suite's teardown being complete. Only directories older than the cutoff are
# touched, which cannot disturb a CONCURRENTLY running suite's tree — those are
# seconds old, and the cutoff is an hour.
#
# Since #821 the scratch lives outside the repo, so this sweeps the scratch
# parent rather than $RESULTS_DIR (which now holds only reports and CI
# artifacts, and must not be reaped). It is also the ONLY reliable cleanup:
# an EXIT trap installed here would be silently replaced by the suites under
# tests/unit/observability that install their own `trap cleanup EXIT`, and it
# would not survive a kill -9 either.
#
# Deliberately silent and non-fatal: this is scratch hygiene, and a failure to
# reap must never redden a test run.
# ============================================================================
tf_reap_stale_temp_dirs() {
    [ -d "$TEST_SCRATCH_PARENT" ] || return 0
    # -mindepth/-maxdepth 1: only the per-suite scratch dirs themselves, never
    # their contents and never the parent. -mmin +60: older than an hour.
    #
    # `-exec` needs a real executable — the `command` builtin the rest of this
    # repo uses for alias-safety is NOT valid there and fails the whole -exec
    # ("-exec command: No such file or directory"), silently, because stderr is
    # suppressed. Hence an absolute rm path, which is alias-proof anyway.
    local rm_bin
    for rm_bin in /bin/rm /usr/bin/rm; do
        [ -x "$rm_bin" ] && break
    done
    [ -x "$rm_bin" ] || return 0
    command find "$TEST_SCRATCH_PARENT" -mindepth 1 -maxdepth 1 -type d -mmin +60 \
        -exec "$rm_bin" -rf {} + 2>/dev/null || true
    return 0
}

# Test counters
declare -g TESTS_RUN=0
declare -g TESTS_PASSED=0
declare -g TESTS_FAILED=0
declare -g TESTS_SKIPPED=0

# Central assertion failure handler
tf_fail_assertion() {
    echo -e "${TEST_COLOR_FAIL}FAIL${TEST_COLOR_RESET}"
    while [ $# -gt 0 ]; do
        echo "    $1"
        shift
    done
    # Only increment TESTS_FAILED once per test (not per assertion)
    if [ "$TEST_STATUS" != "failed" ]; then
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    TEST_STATUS="failed"
    return 1
}

# Current test context
declare -g CURRENT_TEST=""
declare -g CURRENT_SUITE=""
declare -g TEST_STATUS=""

# Colors for output - check if terminal supports color
if [ -t 1 ] && [ -n "${TERM:-}" ] && [ "${TERM}" != "dumb" ] && command -v tput >/dev/null 2>&1; then
    readonly TEST_COLOR_PASS='\033[0;32m'
    readonly TEST_COLOR_FAIL='\033[0;31m'
    readonly TEST_COLOR_SKIP='\033[0;33m'
    readonly TEST_COLOR_INFO='\033[0;36m'
    readonly TEST_COLOR_RESET='\033[0m'
else
    # No color support
    readonly TEST_COLOR_PASS=''
    readonly TEST_COLOR_FAIL=''
    readonly TEST_COLOR_SKIP=''
    readonly TEST_COLOR_INFO=''
    readonly TEST_COLOR_RESET=''
fi

# Initialize test framework
init_test_framework() {
    # Reset test counters for this test run
    TESTS_RUN=0
    TESTS_PASSED=0
    TESTS_FAILED=0
    TESTS_SKIPPED=0
    TEST_STATUS=""

    # Re-clear inherited git env (also cleared at module scope above) so a
    # consumer that re-initialises the framework after mutating the environment
    # still starts from a hermetic git state. See #599 / #587.
    unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR GIT_PREFIX

    # Create directories
    mkdir -p "$RESULTS_DIR"
    mkdir -p "$FIXTURES_DIR"

    tf_reap_stale_temp_dirs

    # Create the parent and the per-run base in two steps, each with an explicit
    # mode. `mkdir -m 700 -p a/b` applies the mode only to the DEEPEST component
    # (SC2174), so a single -p call would leave the parent at whatever the umask
    # allows — the very directory that needs the tight mode, since it is the one
    # sitting in a world-writable tmp root.
    mkdir -p "$TEST_SCRATCH_PARENT"
    chmod 700 "$TEST_SCRATCH_PARENT" 2>/dev/null || true
    mkdir -p "$TEST_SCRATCH_BASE"
    chmod 700 "$TEST_SCRATCH_BASE" 2>/dev/null || true

    # The scratch base is `rm -rf`'d on exit, so an override that points at a
    # real directory would destroy it. Only self-clean a path this framework
    # would have generated — one that still lives under the scratch parent.
    # A relocated override is honored for writing, just never auto-deleted.
    #
    # Best-effort even then: the two suites under tests/unit/observability that
    # install their own `trap cleanup EXIT` silently replace this one, and no
    # trap survives kill -9. The reaper above is the real guarantee.
    case "$TEST_SCRATCH_BASE" in
        "$TEST_SCRATCH_PARENT"/?*)
            trap 'rm -rf "$TEST_SCRATCH_BASE" 2>/dev/null || true' EXIT
            ;;
    esac

    # Set up test environment
    export TEST_MODE=1
    export LOG_LEVEL="${LOG_LEVEL:-1}" # WARN level by default in tests

    # Timestamp for this test run
    export TEST_RUN_ID
    TEST_RUN_ID=$(date +%Y%m%d-%H%M%S)

    # NOTE: init_test_framework deliberately does NOT check for Docker (#831).
    # It used to abort here when `docker` was absent, which gated ~160
    # pure-shell unit suites — none of which touch a daemon — on a tool they
    # never call. Only 5 of 167 suites set the SKIP_DOCKER_CHECK opt-out, so a
    # Docker-free container failed the pre-push `unit-tests` hook for reasons
    # unrelated to the code under test.
    #
    # The gate now lives on the suites that genuinely need a daemon: they call
    # require_docker() (below) explicitly. That is also strictly stronger than
    # the runner-level guards in run_integration_tests.sh / run_all.sh /
    # test_feature.sh, which a suite invoked directly via run_test.sh bypasses.
    #
    # SKIP_DOCKER_CHECK is still accepted as a no-op so the suites and
    # .github/workflows/ci.yml that already export it keep working verbatim.

    echo -e "${TEST_COLOR_INFO}=== Test Framework Initialized ===${TEST_COLOR_RESET}"
    echo "Test run ID: $TEST_RUN_ID"
    echo "Results dir: $RESULTS_DIR"
    echo "Scratch base: $TEST_SCRATCH_BASE"
    if tf_is_incoherent_fs "$TEST_SCRATCH_BASE"; then
        echo -e "${TEST_COLOR_FAIL}WARNING: scratch base is on $(tf_fstype_of "$TEST_SCRATCH_BASE") — write-then-read may be incoherent (#821)${TEST_COLOR_RESET}"
    fi
    echo
}

# Assert a working Docker daemon, aborting the suite if there isn't one.
#
# Call this from any suite that builds or runs containers, immediately after
# init_test_framework. Unit suites must NOT call it — gating Docker-free tests
# on Docker is exactly the defect #831 fixed.
#
# This is the suite-level gate. The runners (run_integration_tests.sh,
# run_all.sh, test_feature.sh) keep their own checks for a faster, clearer
# failure before any suite starts; this one additionally covers a suite
# invoked directly through run_test.sh, which no runner guard sees.
require_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${TEST_COLOR_FAIL}ERROR: Docker is not installed or not in PATH${TEST_COLOR_RESET}" >&2
        echo "This suite builds or runs containers and requires a Docker daemon." >&2
        exit 1
    fi

    if ! docker info >/dev/null 2>&1; then
        echo -e "${TEST_COLOR_FAIL}ERROR: Docker daemon is not running${TEST_COLOR_RESET}" >&2
        exit 1
    fi
}

# Define a test suite
test_suite() {
    local suite_name="$1"
    # shellcheck disable=SC2034  # Set for test consumption
    CURRENT_SUITE="$suite_name"

    echo -e "${TEST_COLOR_INFO}=== Test Suite: $suite_name ===${TEST_COLOR_RESET}"
}

# Define a test
test_case() {
    local test_name="$1"
    # shellcheck disable=SC2034  # Set for test consumption
    CURRENT_TEST="$test_name"
    TESTS_RUN=$((TESTS_RUN + 1))

    echo -n "  $test_name ... "
}

# Pass current test
pass_test() {
    echo -e "${TEST_COLOR_PASS}PASS${TEST_COLOR_RESET}"
    # Only increment TESTS_PASSED once per test (not per assertion)
    if [ "$TEST_STATUS" != "passed" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
    fi
    TEST_STATUS="passed"
}

# Fail current test
fail_test() {
    local reason="$1"
    echo -e "${TEST_COLOR_FAIL}FAIL${TEST_COLOR_RESET}"
    echo "    $reason"
    # Only increment TESTS_FAILED once per test (not per assertion)
    if [ "$TEST_STATUS" != "failed" ]; then
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    TEST_STATUS="failed"
}

# True when network-bound tests should be skipped. The pre-push runner
# (tests/run_changed_tests.sh) exports SKIP_NETWORK_TESTS=1 so routine local
# pushes don't block on api.github.com under concurrent golem load (issue #615);
# CI invokes run_unit_tests.sh directly and leaves the flag unset, so the full
# network matrix still runs there.
network_tests_disabled() {
    [ "${SKIP_NETWORK_TESTS:-}" = "1" ]
}

# Skip current test
skip_test() {
    local reason="$1"
    echo -e "${TEST_COLOR_SKIP}SKIP${TEST_COLOR_RESET}"
    echo "    $reason"
    # Only increment TESTS_SKIPPED once per test
    if [ "$TEST_STATUS" != "skipped" ]; then
        TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
    fi
    TEST_STATUS="skipped"
}

# Setup function (run before each test)
setup() {
    # Create temp directory for test
    export TEST_TEMP_DIR
    TEST_TEMP_DIR=$(mktemp -d -t "container-test-XXXXXX")

    # Track Docker resources created during test
    export TEST_IMAGES=()
    export TEST_CONTAINERS=()
}

# Teardown function (run after each test)
teardown() {
    # Clean up Docker resources
    if [ -n "${TEST_CONTAINERS+x}" ] && [ ${#TEST_CONTAINERS[@]} -gt 0 ]; then
        docker rm -f "${TEST_CONTAINERS[@]}" >/dev/null 2>&1 || true
    fi

    if [ -n "${TEST_IMAGES+x}" ] && [ ${#TEST_IMAGES[@]} -gt 0 ]; then
        docker rmi -f "${TEST_IMAGES[@]}" >/dev/null 2>&1 || true
    fi

    # Clean up temp directory
    if [ -n "${TEST_TEMP_DIR:-}" ] && [ -d "$TEST_TEMP_DIR" ]; then
        rm -rf "$TEST_TEMP_DIR"
    fi

    # Reset environment
    unset TEST_TEMP_DIR TEST_IMAGES TEST_CONTAINERS
}

# Run a test with setup/teardown
run_test() {
    local test_func="$1"
    local test_desc="${2:-$test_func}"

    # Reset test status and output (prevent accumulation)
    TEST_STATUS=""
    # shellcheck disable=SC2034  # Set by helpers.sh, read by assertions
    TEST_OUTPUT=""
    # shellcheck disable=SC2034  # Set by helpers.sh, read by assertions
    TEST_EXIT_CODE=0

    # Show test description
    test_case "$test_desc"

    # Run setup
    setup

    # Run the test
    if $test_func; then
        # Only mark as passed if not already marked as skipped or failed
        if [ "$TEST_STATUS" != "skipped" ] && [ "$TEST_STATUS" != "failed" ]; then
            pass_test
        fi
    fi

    # Run teardown
    teardown
}

# Start a test (compatibility function for inline test descriptions)
# Usage: start_test "Description of what this test does"
start_test() {
    local description="$1"
    # This is a no-op for inline descriptions within test functions
    # The actual test tracking is done by run_test
    :
}

# Assert command succeeded (compatibility function)
# Usage: assert_success "Description of what should succeed"
assert_success() {
    local description="${1:-Command should succeed}"
    # This is effectively a no-op since test functions that reach this
    # point without exiting have succeeded
    :
}

# Assert command exists (check if command is available in PATH or as function)
# Usage: assert_command_exists "command_name" "Description"
assert_command_exists() {
    local cmd="$1"
    local description="${2:-Command $cmd should exist}"

    if command -v "$cmd" >/dev/null 2>&1; then
        # Command exists (in PATH or as function/alias/builtin)
        return 0
    else
        # Command doesn't exist - fail the assertion
        tf_fail_assertion "$description (command '$cmd' not found)"
        return 1
    fi
}

# Assert file is executable (compatibility alias for assert_executable)
# Usage: assert_file_executable "file_path" "Description"
assert_file_executable() {
    assert_executable "$@"
}

# Run multiple tests with a suite name (convenience function)
# Usage: run_tests "Suite Name" test_func1 test_func2 test_func3
run_tests() {
    local suite_name="$1"
    shift

    # Initialize framework if not already initialized
    # Check TEST_RUN_ID instead of TESTS_RUN since RUN_ID is only set in init
    if [ -z "${TEST_RUN_ID:-}" ]; then
        init_test_framework
    fi

    # Set the test suite
    test_suite "$suite_name"

    # Run each test function
    for test_func in "$@"; do
        run_test "$test_func" "$test_func"
    done

    # Generate report
    generate_report
}

# Generate test report
generate_report() {
    local report_file="$RESULTS_DIR/test-report-$TEST_RUN_ID.txt"

    {
        echo "Test Report"
        echo "==========="
        echo "Date: $(date)"
        echo "Test Run ID: $TEST_RUN_ID"
        echo
        echo "Summary:"
        echo "  Total Tests: $TESTS_RUN"
        echo "  Passed:      $TESTS_PASSED"
        echo "  Failed:      $TESTS_FAILED"
        echo "  Skipped:     $TESTS_SKIPPED"
        echo

        local pass_rate=0
        if [ $TESTS_RUN -gt 0 ]; then
            pass_rate=$((TESTS_PASSED * 100 / TESTS_RUN))
        fi
        echo "  Pass Rate:   ${pass_rate}%"

    } | command tee "$report_file"

    echo
    echo "Report saved to: $report_file"

    # Return non-zero if any tests failed
    [ $TESTS_FAILED -eq 0 ]
}

# Export framework core functions
export -f test_suite test_case
export -f tf_fail_assertion
export -f pass_test fail_test skip_test network_tests_disabled
export -f setup teardown run_test run_tests
export -f start_test assert_success assert_command_exists assert_file_executable
export -f init_test_framework generate_report
export -f tf_fstype_of tf_is_incoherent_fs tf_scratch_root
