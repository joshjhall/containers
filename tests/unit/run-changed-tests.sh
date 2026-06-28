#!/usr/bin/env bash
# Unit tests for the pre-push network-test skip wiring (issue #615).
#
# Background: the lefthook pre-push hook runs tests/run_changed_tests.sh. When a
# foundational file (tests/framework.sh, tests/framework/*, Dockerfile) changes,
# that runner maps to ALL and execs the whole unit suite — which includes
# tests/unit/bin/check-versions.sh, a test that invokes the real
# bin/check-versions.sh and curls api.github.com once per tracked tool. Under
# concurrent golems those calls serialize and a git push stalls for minutes.
#
# The fix: run_changed_tests.sh exports SKIP_NETWORK_TESTS=1, and live-network
# tests skip via the network_tests_disabled helper. CI is unaffected because it
# invokes run_unit_tests.sh directly (the flag stays unset there). These tests
# lock that wiring in so a future edit can't silently restore the live calls to
# the push gate.

set -euo pipefail

# Source test framework
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "Pre-push network-test skip wiring (#615)"

FRAMEWORK="$PROJECT_ROOT/tests/framework.sh"
RUNNER="$PROJECT_ROOT/tests/run_changed_tests.sh"
CHECK_VERSIONS_TEST="$PROJECT_ROOT/tests/unit/bin/check-versions.sh"
VERSION_RESOLUTION_TEST="$PROJECT_ROOT/tests/unit/base/version-resolution.sh"

# The runner is what the pre-push hook invokes; it must set the flag so the ALL
# path and per-file invocations both skip network tests.
test_runner_exports_flag() {
    if command grep -qE '^[[:space:]]*export SKIP_NETWORK_TESTS=' "$RUNNER"; then
        pass_test "run_changed_tests.sh exports SKIP_NETWORK_TESTS"
    else
        fail_test "run_changed_tests.sh must export SKIP_NETWORK_TESTS (pre-push gate)"
    fi
}

# The helper is the single consultation point; it must be defined and exported
# so subprocess test files inherit it.
test_framework_defines_helper() {
    assert_contains "$(/usr/bin/cat "$FRAMEWORK")" "network_tests_disabled()" \
        "framework.sh defines network_tests_disabled"
}

test_framework_exports_helper() {
    if command grep -qE '^export -f .*network_tests_disabled' "$FRAMEWORK"; then
        pass_test "framework.sh exports network_tests_disabled"
    else
        fail_test "framework.sh must export -f network_tests_disabled (subprocess inheritance)"
    fi
}

test_helper_keys_on_env() {
    assert_contains "$(/usr/bin/cat "$FRAMEWORK")" 'SKIP_NETWORK_TESTS:-' \
        "network_tests_disabled keys on the SKIP_NETWORK_TESTS env var"
}

# The named culprit: each live-script test must be guarded by name. Asserting on
# the specific function bodies (rather than a count threshold) means a newly
# added unguarded network test is caught, not masked by the existing guards.
test_check_versions_guards_live_tests() {
    local func
    for func in test_missing_env_file test_json_output_format test_json_output_valid; do
        # The guard must appear within ~6 lines of the function header.
        if command grep -A6 "^${func}()" "$CHECK_VERSIONS_TEST" |
            command grep -q "network_tests_disabled"; then
            pass_test "check-versions.sh guards $func with network_tests_disabled"
        else
            fail_test "check-versions.sh must guard $func with network_tests_disabled"
        fi
    done
}

# version-resolution.sh routes ~18 network tests through check_network; that
# helper must honor the flag too.
test_version_resolution_honors_flag() {
    assert_contains "$(/usr/bin/cat "$VERSION_RESOLUTION_TEST")" "network_tests_disabled" \
        "version-resolution.sh check_network honors the skip flag"
}

# Behavioral checks of the already-sourced helper. We toggle SKIP_NETWORK_TESTS
# in-process (save/restore) rather than spawning `bash -c "source ...; ..."` —
# inside `bash -c` BASH_SOURCE[0] is empty, so framework.sh's TESTS_DIR would
# resolve to the cwd and the helper would never load. One assertion per test so
# run_test's per-test PASS/FAIL accounting stays correct.
test_helper_enabled() {
    local saved="${SKIP_NETWORK_TESTS:-}"
    SKIP_NETWORK_TESTS=1
    if network_tests_disabled; then
        pass_test "network_tests_disabled true when SKIP_NETWORK_TESTS=1"
    else
        fail_test "network_tests_disabled should be true when SKIP_NETWORK_TESTS=1"
    fi
    SKIP_NETWORK_TESTS="$saved"
}

test_helper_dev_override() {
    local saved="${SKIP_NETWORK_TESTS:-}"
    SKIP_NETWORK_TESTS=0
    if network_tests_disabled; then
        fail_test "network_tests_disabled should be false when SKIP_NETWORK_TESTS=0"
    else
        pass_test "network_tests_disabled false when SKIP_NETWORK_TESTS=0"
    fi
    SKIP_NETWORK_TESTS="$saved"
}

# The unset case is the CI path (run_unit_tests.sh leaves the flag unset and
# must run the full network matrix). Guard against a regression that treats
# "unset" as "disabled".
test_helper_ci_path_unset() {
    local saved="${SKIP_NETWORK_TESTS:-}"
    unset SKIP_NETWORK_TESTS
    if network_tests_disabled; then
        fail_test "network_tests_disabled should be false when unset (CI path)"
    else
        pass_test "network_tests_disabled false when SKIP_NETWORK_TESTS unset (CI path)"
    fi
    [ -n "$saved" ] && export SKIP_NETWORK_TESTS="$saved"
    return 0
}

run_test test_runner_exports_flag "Pre-push runner exports SKIP_NETWORK_TESTS"
run_test test_framework_defines_helper "framework.sh defines network_tests_disabled"
run_test test_framework_exports_helper "framework.sh exports network_tests_disabled"
run_test test_helper_keys_on_env "Helper keys on SKIP_NETWORK_TESTS env var"
run_test test_check_versions_guards_live_tests "check-versions.sh guards live-script tests"
run_test test_version_resolution_honors_flag "version-resolution.sh honors skip flag"
run_test test_helper_enabled "network_tests_disabled true when flag=1"
run_test test_helper_dev_override "network_tests_disabled false when flag=0"
run_test test_helper_ci_path_unset "network_tests_disabled false when flag unset (CI)"

# Generate test report
generate_report
