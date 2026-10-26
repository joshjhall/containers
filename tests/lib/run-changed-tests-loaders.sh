#!/usr/bin/env bash
# Shared loaders for the changed-test runner suites (#1480):
# tests/unit/run-changed-tests.sh and tests/unit/run-changed-tests-evidence.sh.
# Sourced only — it lives outside tests/unit/ so the unit runner does not
# execute it as a suite. Callers source tests/framework.sh first: RUNNER is
# built from its PROJECT_ROOT.

RUNNER="$PROJECT_ROOT/tests/run_changed_tests.sh"

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

# Extract map_changed_files (the main block's per-line collection loop).
# Same trust boundary as _load_map_to_test above.
_load_map_changed_files() {
    local body
    _load_map_to_test || return 1
    body=$(/usr/bin/awk '/^map_changed_files\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$RUNNER")
    [ -n "$body" ] || return 1
    eval "$body"
}

# Extract collect_test_files (the main block's dedupe / ALL / GO_TEST step).
# Same trust boundary as _load_map_to_test above.
_load_collect_test_files() {
    local body
    _load_map_changed_files || return 1
    body=$(/usr/bin/awk '/^collect_test_files\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$RUNNER")
    [ -n "$body" ] || return 1
    eval "$body"
}
