#!/usr/bin/env bash
# Unit tests for lib/runtime/commands/recover-entrypoint
# Verifies the structural invariants of the entrypoint-replay helper.

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Recover-Entrypoint Helper Tests"

# Path to the script under test
RECOVER_SCRIPT="$PROJECT_ROOT/lib/runtime/commands/recover-entrypoint"

# ---------------------------------------------------------------------------
# Static analysis tests
# ---------------------------------------------------------------------------

# Test: Strict error handling
test_strict_mode() {
    assert_file_contains "$RECOVER_SCRIPT" 'set -euo pipefail' \
        "Should enable strict error handling"
}

# Test: Marker path is ~/.container-initialized
test_marker_path() {
    assert_file_contains "$RECOVER_SCRIPT" 'MARKER="\$HOME/.container-initialized"' \
        "Should use \$HOME/.container-initialized as the marker"
}

# Test: Fast-path exit when marker exists
test_marker_short_circuit() {
    assert_file_contains "$RECOVER_SCRIPT" 'if \[ -f "\$MARKER" \]' \
        "Should check whether marker exists"
    assert_file_contains "$RECOVER_SCRIPT" 'exit 0' \
        "Should exit 0 when marker exists (idempotency)"
}

# Test: Skips gracefully when entrypoint binary missing
test_entrypoint_missing_guard() {
    assert_file_contains "$RECOVER_SCRIPT" '\[ ! -x /usr/local/bin/entrypoint \]' \
        "Should guard against missing /usr/local/bin/entrypoint"
}

# Test: Invokes entrypoint with /usr/bin/true so it execs cleanly
test_invokes_entrypoint_with_true() {
    assert_file_contains "$RECOVER_SCRIPT" '/usr/local/bin/entrypoint /usr/bin/true' \
        "Should invoke entrypoint with /usr/bin/true as the exec command"
}

# Test: Does NOT use sudo (entrypoint sudos internally for privileged steps)
test_no_explicit_sudo() {
    assert_false "command grep -q '^[^#]*sudo ' '$RECOVER_SCRIPT'" \
        "Should not call sudo explicitly — entrypoint uses run_privileged internally"
}

# Test: Emits a recognizable log line so operators can see the replay happen
test_logs_replay() {
    assert_file_contains "$RECOVER_SCRIPT" '\[recover-entrypoint\]' \
        "Should emit log lines tagged [recover-entrypoint]"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
run_test test_strict_mode "Strict mode (set -euo pipefail)"
run_test test_marker_path "Marker path is \$HOME/.container-initialized"
run_test test_marker_short_circuit "Short-circuits when marker exists"
run_test test_entrypoint_missing_guard "Guards against missing entrypoint binary"
run_test test_invokes_entrypoint_with_true "Invokes entrypoint with /usr/bin/true"
run_test test_no_explicit_sudo "Does not call sudo explicitly"
run_test test_logs_replay "Emits [recover-entrypoint] log lines"

# Generate test report
generate_report
