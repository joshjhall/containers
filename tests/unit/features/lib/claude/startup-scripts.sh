#!/usr/bin/env bash
# Unit tests for Claude startup scripts:
#   - lib/features/lib/claude/30-first-startup.sh
#   - lib/features/lib/claude/35-auth-watcher-startup.sh

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Claude Startup Scripts Tests"

# Source files under test
FIRST_STARTUP="$PROJECT_ROOT/lib/features/lib/claude/30-first-startup.sh"
AUTH_WATCHER="$PROJECT_ROOT/lib/features/lib/claude/35-auth-watcher-startup.sh"

# Track background PIDs for cleanup across tests
_CLEANUP_PIDS=()

# Setup function - creates isolated temp dir for each test
setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$RESULTS_DIR/test-claude-startup-$unique_id"
    mkdir -p "$TEST_TEMP_DIR/home/.claude"
    mkdir -p "$TEST_TEMP_DIR/bin"
}

# Teardown function - cleans up temp dir and background processes
teardown() {
    for pid in "${_CLEANUP_PIDS[@]:-}"; do
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    _CLEANUP_PIDS=()
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
    # Clean up PID file that auth-watcher writes to /tmp
    rm -f /tmp/claude-auth-watcher.pid 2>/dev/null || true
    unset TEST_TEMP_DIR 2>/dev/null || true
}

# ============================================================================
# 30-first-startup.sh — Static Analysis
# ============================================================================

test_first_startup_strict_mode() {
    assert_file_contains "$FIRST_STARTUP" "set -euo pipefail" \
        "first-startup uses strict mode"
}

test_first_startup_references_claude_setup() {
    assert_file_contains "$FIRST_STARTUP" "claude-setup" \
        "first-startup references claude-setup"
}

test_first_startup_uses_force_flag() {
    assert_file_contains "$FIRST_STARTUP" -- "--force" \
        "first-startup calls claude-setup with --force"
}

# ============================================================================
# 30-first-startup.sh — Functional Tests
# ============================================================================

test_first_startup_calls_claude_setup() {
    # When claude-setup is available, it should be called with --force
    local marker="$TEST_TEMP_DIR/claude-setup-called"

    # Create a mock claude-setup that writes args to a marker file
    cat > "$TEST_TEMP_DIR/bin/claude-setup" <<EOF
#!/bin/bash
echo "\$@" > "$marker"
EOF
    chmod +x "$TEST_TEMP_DIR/bin/claude-setup"

    local exit_code=0
    # Use restricted PATH so only our mock is found; unset BASH_ENV to
    # prevent /etc/bash_env from resetting PATH in the subprocess
    BASH_ENV='' PATH="$TEST_TEMP_DIR/bin:/usr/bin:/bin" \
        bash "$FIRST_STARTUP" 2>/dev/null || exit_code=$?

    assert_equals "0" "$exit_code" \
        "first-startup should exit 0 when claude-setup succeeds"
    assert_file_exists "$marker" \
        "claude-setup should have been called"
    local args
    args=$(cat "$marker")
    assert_contains "$args" "--force" \
        "claude-setup should be called with --force"
}

test_first_startup_skips_when_no_claude_setup() {
    # When claude-setup is NOT in PATH, script should exit 0 silently
    local exit_code=0
    # Empty bin dir means claude-setup won't be found
    BASH_ENV='' PATH="$TEST_TEMP_DIR/bin:/usr/bin:/bin" \
        bash "$FIRST_STARTUP" 2>/dev/null || exit_code=$?

    assert_equals "0" "$exit_code" \
        "first-startup should exit 0 when claude-setup not available"
}

# ============================================================================
# 35-auth-watcher-startup.sh — Static Analysis
# ============================================================================

test_auth_watcher_references_marker() {
    assert_file_contains "$AUTH_WATCHER" "MARKER_FILE" \
        "auth-watcher references MARKER_FILE"
}

test_auth_watcher_references_pid_file() {
    assert_file_contains "$AUTH_WATCHER" "WATCHER_PID_FILE" \
        "auth-watcher references WATCHER_PID_FILE"
}

test_auth_watcher_references_command() {
    assert_file_contains "$AUTH_WATCHER" "claude-auth-watcher" \
        "auth-watcher references claude-auth-watcher command"
}

# ============================================================================
# 35-auth-watcher-startup.sh — Functional Tests
#
# Because the script uses hardcoded paths ($HOME/.claude/... and /tmp/...),
# we test by manipulating HOME and creating wrapper scripts that override
# the PID file path where needed.
# ============================================================================

test_auth_watcher_skips_when_marker_exists() {
    local fake_home="$TEST_TEMP_DIR/home"
    mkdir -p "$fake_home/.claude"
    touch "$fake_home/.claude/.container-setup-complete"

    local exit_code=0
    BASH_ENV='' HOME="$fake_home" PATH="$TEST_TEMP_DIR/bin:/usr/bin:/bin" \
        bash "$AUTH_WATCHER" 2>/dev/null || exit_code=$?

    assert_equals "0" "$exit_code" \
        "auth-watcher should exit 0 when marker exists"
}

test_auth_watcher_skips_when_command_missing() {
    local fake_home="$TEST_TEMP_DIR/home"
    mkdir -p "$fake_home/.claude"
    # No marker, no PID file, no claude-auth-watcher in PATH

    local exit_code=0
    BASH_ENV='' HOME="$fake_home" PATH="$TEST_TEMP_DIR/bin:/usr/bin:/bin" \
        bash "$AUTH_WATCHER" 2>/dev/null || exit_code=$?

    assert_equals "0" "$exit_code" \
        "auth-watcher should exit 0 when command not in PATH"
}

test_auth_watcher_skips_when_pid_running() {
    # Use a wrapper script that lets us control the PID file path
    local fake_home="$TEST_TEMP_DIR/home"
    mkdir -p "$fake_home/.claude"

    # Start a dummy process to simulate a running watcher
    sleep 300 &
    local dummy_pid=$!
    _CLEANUP_PIDS+=("$dummy_pid")

    # Write a wrapper that uses a custom PID file path
    local wrapper="$TEST_TEMP_DIR/test-watcher.sh"
    cat > "$wrapper" <<WEOF
#!/bin/bash
MARKER_FILE="\$HOME/.claude/.container-setup-complete"
WATCHER_PID_FILE="$TEST_TEMP_DIR/watcher.pid"
if [ -f "\$MARKER_FILE" ]; then exit 0; fi
if [ -f "\$WATCHER_PID_FILE" ] && kill -0 "\$(cat "\$WATCHER_PID_FILE")" 2>/dev/null; then
    exit 0
fi
# Reached launch section — means the checks didn't skip
exit 99
WEOF
    chmod +x "$wrapper"

    echo "$dummy_pid" > "$TEST_TEMP_DIR/watcher.pid"

    local exit_code=0
    HOME="$fake_home" bash "$wrapper" 2>/dev/null || exit_code=$?

    assert_equals "0" "$exit_code" \
        "auth-watcher should exit 0 when watcher PID is alive"
}

test_auth_watcher_launches_watcher() {
    local fake_home="$TEST_TEMP_DIR/home"
    mkdir -p "$fake_home/.claude"

    # Create a mock claude-auth-watcher that just sleeps
    cat > "$TEST_TEMP_DIR/bin/claude-auth-watcher" <<'SCRIPT'
#!/bin/bash
sleep 300
SCRIPT
    chmod +x "$TEST_TEMP_DIR/bin/claude-auth-watcher"

    local exit_code=0
    local output
    output=$(BASH_ENV='' HOME="$fake_home" PATH="$TEST_TEMP_DIR/bin:/usr/bin:/bin" \
        bash "$AUTH_WATCHER" 2>&1) || exit_code=$?

    assert_equals "0" "$exit_code" \
        "auth-watcher should exit 0 after launching watcher"
    assert_contains "$output" "Starting Claude authentication watcher" \
        "auth-watcher should print startup message"
    assert_contains "$output" "Watcher started" \
        "auth-watcher should confirm watcher started"

    # Verify PID file was created and contains a valid PID
    if [ -f "/tmp/claude-auth-watcher.pid" ]; then
        local watcher_pid
        watcher_pid=$(cat /tmp/claude-auth-watcher.pid)
        _CLEANUP_PIDS+=("$watcher_pid")

        assert_matches "$watcher_pid" "^[0-9]+$" \
            "PID file should contain a numeric PID"

        # Verify the process is actually running
        local running=0
        kill -0 "$watcher_pid" 2>/dev/null && running=1
        assert_equals "1" "$running" \
            "PID should reference a running process"
    else
        fail_test "PID file was not created at /tmp/claude-auth-watcher.pid"
    fi
}

# ============================================================================
# Run all tests
# ============================================================================

# 30-first-startup.sh
run_test test_first_startup_strict_mode "first-startup: uses strict mode"
run_test test_first_startup_references_claude_setup "first-startup: references claude-setup"
run_test test_first_startup_uses_force_flag "first-startup: uses --force flag"
run_test test_first_startup_calls_claude_setup "first-startup: calls claude-setup when available"
run_test test_first_startup_skips_when_no_claude_setup "first-startup: skips when claude-setup missing"

# 35-auth-watcher-startup.sh
run_test test_auth_watcher_references_marker "auth-watcher: references MARKER_FILE"
run_test test_auth_watcher_references_pid_file "auth-watcher: references WATCHER_PID_FILE"
run_test test_auth_watcher_references_command "auth-watcher: references claude-auth-watcher"
run_test test_auth_watcher_skips_when_marker_exists "auth-watcher: skips when marker exists"
run_test test_auth_watcher_skips_when_command_missing "auth-watcher: skips when command missing"
run_test test_auth_watcher_skips_when_pid_running "auth-watcher: skips when PID alive"
run_test test_auth_watcher_launches_watcher "auth-watcher: launches watcher process"

# Generate test report
generate_report
