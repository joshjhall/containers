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

# ============================================================================
# Runtime-script test mapping (issue #832)
# ============================================================================
# The lib/runtime arm of map_to_test used to match on the bare basename, so
# lib/runtime/42-workspace-fs-health.sh resolved to
# tests/unit/runtime/42-workspace-fs-health.sh — a path that has never existed.
# The arm emitted nothing and the runner treated that as "no tests needed", so a
# changed runtime script ran no tests at push time with no error to notice.
# Splitting a suite into siblings (#832) made a second failure mode reachable:
# emitting only the first glob match would silently narrow coverage.
#
# These call map_to_test directly rather than grepping the runner's source, so
# they assert what it RESOLVES, not how it is spelled.

# Extract map_to_test from the runner into this shell. The function is
# self-contained (it reads only $TESTS_DIR/$PROJECT_ROOT and echoes paths), so
# it can be evaluated without executing the runner's push-time side effects.
#
# SECURITY: this `eval`s text read from $RUNNER. That is safe ONLY because
# $RUNNER is a fixed repo-local path ($PROJECT_ROOT/tests/run_changed_tests.sh)
# with no env or CLI override — it is the same trust boundary as sourcing the
# file. If $RUNNER ever becomes configurable, this becomes a code-injection
# path into the test process and must be replaced by sourcing a dedicated
# fragment instead of parsing one out.
_load_map_to_test() {
    local body
    body=$(/usr/bin/awk '/^map_to_test\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$RUNNER")
    [ -n "$body" ] || return 1
    eval "$body"
}

test_runtime_mapping_strips_order_prefix() {
    local out
    if ! _load_map_to_test; then
        fail_test "could not extract map_to_test from $RUNNER"
        return 0
    fi

    out=$(map_to_test "lib/runtime/42-workspace-fs-health.sh")
    assert_contains "$out" "tests/unit/runtime/workspace-fs-health.sh" \
        "NN- prefixed runtime script must map to its unprefixed suite"
}

test_runtime_mapping_emits_all_siblings() {
    local out count
    if ! _load_map_to_test; then
        fail_test "could not extract map_to_test from $RUNNER"
        return 0
    fi

    out=$(map_to_test "lib/runtime/42-workspace-fs-health.sh")

    # Pin every known sibling by NAME, not a loose count. A bare `count > 1`
    # would stay green if the glob silently dropped one of the three, which is
    # the same "coverage narrows and nobody notices" failure this arm exists to
    # prevent. Three suites cover this script today: the split pair (#832) plus
    # the pre-existing cron-entry suite.
    assert_contains "$out" "workspace-fs-health.sh" \
        "the exact-match suite must be included"
    assert_contains "$out" "workspace-fs-health-submodules.sh" \
        "split sibling suite must be included, not just the first glob match"
    assert_contains "$out" "workspace-fs-health-cron-entry.sh" \
        "pre-existing cron-entry sibling must be included"

    # Every emitted path must be a real file — a stale glob would otherwise
    # feed a nonexistent path to the runner.
    count=0
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        count=$((count + 1))
        assert_file_exists "$path" "mapped test path must exist: $path"
    done <<<"$out"

    assert_equals "3" "$count" \
        "exactly the three known workspace-fs-health suites must be mapped"
}

test_runtime_mapping_keeps_prefixed_suites() {
    local out
    if ! _load_map_to_test; then
        fail_test "could not extract map_to_test from $RUNNER"
        return 0
    fi

    # The test files are INCONSISTENT about keeping the NN- prefix, so both
    # spellings must resolve. These two keep theirs; workspace-fs-health drops
    # it. A stripped-only lookup silently breaks these.
    out=$(map_to_test "lib/runtime/05-cleanup-init-env.sh")
    assert_contains "$out" "tests/unit/runtime/05-cleanup-init-env.sh" \
        "a runtime suite that KEEPS its NN- prefix must still be found"

    out=$(map_to_test "lib/runtime/60-setup-git.sh")
    assert_contains "$out" "tests/unit/runtime/60-setup-git.sh" \
        "60-setup-git.sh must map to its OWN suite, not the stripped-name one"
}

test_runtime_mapping_no_duplicate_paths() {
    local out uniq_count total_count
    if ! _load_map_to_test; then
        fail_test "could not extract map_to_test from $RUNNER"
        return 0
    fi

    # An unprefixed script makes the prefixed and stripped passes identical, so
    # without dedup every path would be emitted twice and run twice.
    out=$(map_to_test "lib/runtime/audit-logger.sh")
    total_count=$(command printf '%s\n' "$out" | command grep -c . || true)
    uniq_count=$(command printf '%s\n' "$out" | command grep . | command sort -u | command wc -l)

    assert_equals "$total_count" "$uniq_count" \
        "map_to_test must not emit the same test path twice"
}

test_runtime_mapping_unmatched_is_silent() {
    local out
    if ! _load_map_to_test; then
        fail_test "could not extract map_to_test from $RUNNER"
        return 0
    fi

    # A runtime script with no suite must emit nothing rather than a bogus path.
    out=$(map_to_test "lib/runtime/99-no-such-runtime-script.sh")
    assert_empty "$out" "an uncovered runtime script must map to no test path"
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
run_test test_runtime_mapping_strips_order_prefix "runtime mapping strips the NN- order prefix (#832)"
run_test test_runtime_mapping_emits_all_siblings "runtime mapping emits every sibling suite (#832)"
run_test test_runtime_mapping_unmatched_is_silent "uncovered runtime script maps to no test path (#832)"
run_test test_runtime_mapping_keeps_prefixed_suites "runtime mapping finds suites that keep the NN- prefix (#832)"
run_test test_runtime_mapping_no_duplicate_paths "runtime mapping emits no duplicate test paths (#832)"

# Generate test report
generate_report
