#!/usr/bin/env bash
# Unit tests for .devcontainer/post-start.sh
# Tests the every-start devcontainer hook: step order and abort semantics

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Devcontainer Post-Start Tests"

SCRIPT="$PROJECT_ROOT/.devcontainer/post-start.sh"

# Build a PATH shim dir of stub commands that log their name to $dir/calls.
# Args: dir, then "name:rc" pairs.
_make_stubs() {
    local dir=$1
    shift
    command mkdir -p "$dir/bin"
    : >"$dir/calls"
    local spec name rc
    for spec in "$@"; do
        name=${spec%%:*}
        rc=${spec##*:}
        command printf '#!/bin/sh\necho %s >>"%s/calls"\nexit %s\n' "$name" "$dir" "$rc" >"$dir/bin/$name"
        command chmod +x "$dir/bin/$name"
    done
}

# Run post-start.sh with the stub dir first on PATH. BASH_ENV is unset because
# the container's /etc/bash_env re-prepends system dirs to PATH in every
# non-interactive bash, which would let the REAL recover-entrypoint / setup-git
# shadow the stubs (and run for real).
_run_with_stubs() {
    command env -u BASH_ENV PATH="$1/bin:$PATH" bash "$SCRIPT"
}

test_script_exists() {
    assert_file_exists "$SCRIPT"
    assert_executable "$SCRIPT"
}

test_script_uses_strict_mode() {
    assert_file_contains "$SCRIPT" "^set -euo pipefail" "post-start.sh runs under set -euo pipefail"
}

# Every step runs, in the order the old inline chain used.
test_runs_steps_in_order() {
    local dir="$TEST_TEMP_DIR/ok" rc=0
    _make_stubs "$dir" recover-entrypoint:0 setup-git:0 setup-gh:0

    _run_with_stubs "$dir" >/dev/null 2>&1 || rc=$?

    assert_equals "0" "$rc" "post-start.sh exits 0 when every step succeeds"
    assert_equals "recover-entrypoint setup-git setup-gh" "$(command tr '\n' ' ' <"$dir/calls" | command sed 's/ $//')" \
        "Steps run as recover-entrypoint → setup-git → setup-gh"
}

# A failing step aborts the rest (the old `&&` semantics).
test_failing_step_aborts_rest() {
    local dir="$TEST_TEMP_DIR/fail" rc=0
    _make_stubs "$dir" recover-entrypoint:3 setup-git:0 setup-gh:0

    _run_with_stubs "$dir" >/dev/null 2>&1 || rc=$?

    assert_equals "3" "$rc" "post-start.sh propagates the failing step's exit code"
    assert_equals "recover-entrypoint" "$(command cat "$dir/calls")" \
        "setup-git / setup-gh are skipped after recover-entrypoint fails"
}

# A failure mid-chain skips only the steps after it.
test_failing_middle_step_skips_rest() {
    local dir="$TEST_TEMP_DIR/mid" rc=0
    _make_stubs "$dir" recover-entrypoint:0 setup-git:5 setup-gh:0

    _run_with_stubs "$dir" >/dev/null 2>&1 || rc=$?

    assert_equals "5" "$rc" "post-start.sh propagates setup-git's exit code"
    assert_equals "recover-entrypoint setup-git" "$(command tr '\n' ' ' <"$dir/calls" | command sed 's/ $//')" \
        "setup-gh is skipped after setup-git fails"
}

run_test test_script_exists "post-start.sh exists and is executable"
run_test test_script_uses_strict_mode "post-start.sh uses strict mode"
run_test test_runs_steps_in_order "Steps run in order"
run_test test_failing_step_aborts_rest "A failing step aborts the rest"
run_test test_failing_middle_step_skips_rest "A failing middle step skips the rest"

# Generate test report
generate_report
