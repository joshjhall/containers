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
    export TEST_TEMP_DIR="$TEST_SCRATCH_BASE/test-claude-startup-$unique_id"
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
    # When claude-setup is available, it should be launched in the background
    # with --force. The mock writes args to a marker file.
    local marker="$TEST_TEMP_DIR/claude-setup-called"

    # Create a mock claude-setup that writes args to a marker file
    command cat >"$TEST_TEMP_DIR/bin/claude-setup" <<EOF
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
        "first-startup should exit 0 when claude-setup is backgrounded"

    # Wait briefly for the background process to complete (mock is instant)
    local waited=0
    while [ ! -f "$marker" ] && [ "$waited" -lt 5 ]; do
        sleep 0.1
        waited=$((waited + 1))
    done

    assert_file_exists "$marker" \
        "claude-setup should have been called (background)"
    local args
    args=$(command cat "$marker")
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
    command cat >"$wrapper" <<WEOF
#!/bin/bash
MARKER_FILE="\$HOME/.claude/.container-setup-complete"
WATCHER_PID_FILE="$TEST_TEMP_DIR/watcher.pid"
if [ -f "\$MARKER_FILE" ]; then exit 0; fi
if [ -f "\$WATCHER_PID_FILE" ] && kill -0 "\$(command cat "\$WATCHER_PID_FILE")" 2>/dev/null; then
    exit 0
fi
# Reached launch section — means the checks didn't skip
exit 99
WEOF
    chmod +x "$wrapper"

    echo "$dummy_pid" >"$TEST_TEMP_DIR/watcher.pid"

    local exit_code=0
    HOME="$fake_home" bash "$wrapper" 2>/dev/null || exit_code=$?

    assert_equals "0" "$exit_code" \
        "auth-watcher should exit 0 when watcher PID is alive"
}

test_auth_watcher_launches_watcher() {
    local fake_home="$TEST_TEMP_DIR/home"
    mkdir -p "$fake_home/.claude"

    # Create a mock claude-auth-watcher that just sleeps
    command cat >"$TEST_TEMP_DIR/bin/claude-auth-watcher" <<'SCRIPT'
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
        watcher_pid=$(command cat /tmp/claude-auth-watcher.pid)
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
# ============================================================================
# claude-auth-watcher / claude-setup — externally authenticated op (#1711)
# ============================================================================
CLAUDE_AUTH_WATCHER_BIN="$PROJECT_ROOT/lib/features/lib/claude/claude-auth-watcher"
CLAUDE_SETUP_BIN="$PROJECT_ROOT/lib/features/lib/claude/claude-setup"

# Extract the watcher's helper functions (everything before is_authenticated)
# into a scratch file with the token file redirected to scratch — the real
# /dev/shm/anthropic-auth-token is this container's live token and must never
# be read or written by a test. The early "marker exists → exit" guard is
# neutralised by pointing HOME at an empty scratch dir.
_watcher_helpers() {
    local out="$TEST_TEMP_DIR/watcher-helpers.sh"
    command sed -n '1,/^is_authenticated() {$/p' "$CLAUDE_AUTH_WATCHER_BIN" |
        command sed '$d' |
        command sed "s|/dev/shm/anthropic-auth-token|$TEST_TEMP_DIR/anthropic-auth-token|" >"$out"
    printf '%s' "$out"
}

# Stub op: whoami exits $1; read prints a fixed token.
_stub_claude_op() {
    printf '#!/bin/bash\necho "$*" >>"%s/op.calls"\ncase "$1" in whoami) exit %s ;; read) printf fake-anthropic-token-1711 ;; esac\n' \
        "$TEST_TEMP_DIR" "$1" >"$TEST_TEMP_DIR/bin/op"
    chmod +x "$TEST_TEMP_DIR/bin/op"
}

_resolve_via_watcher() {
    local helpers
    helpers=$(_watcher_helpers)
    command env -i BASH_ENV= HOME="$TEST_TEMP_DIR/home" \
        PATH="$TEST_TEMP_DIR/bin:/usr/bin:/bin" \
        OP_USABLE_LIB="$PROJECT_ROOT/lib/runtime/lib/op-usable.sh" \
        OP_WHOAMI_CACHE_DIR="$TEST_TEMP_DIR" \
        CONTAINER_CREDENTIAL_ENV_FILE="$TEST_TEMP_DIR/no-credential-env" \
        OP_ANTHROPIC_AUTH_TOKEN_REF="op://vault/anthropic/token" \
        "$@" \
        bash -c '. "$1" >/dev/null; if _try_resolve_op_secrets >/dev/null; then echo resolved; else echo skipped; fi' _ "$helpers"
}

test_watcher_resolves_with_external_op() {
    _stub_claude_op 0
    assert_equals "resolved" "$(_resolve_via_watcher)" \
        "No token in env, op whoami ok: OP_ANTHROPIC_AUTH_TOKEN_REF resolves"
    assert_file_contains "$TEST_TEMP_DIR/anthropic-auth-token" "fake-anthropic-token-1711" \
        "Resolved token is stored (scratch path, never the live one)"
}

test_watcher_skips_without_auth() {
    _stub_claude_op 1
    assert_equals "skipped" "$(_resolve_via_watcher)" \
        "No token and op whoami fails: skip, as today"
    assert_file_not_contains "$TEST_TEMP_DIR/op.calls" "read" "No op read attempted"
}

test_watcher_token_path_unchanged() {
    _stub_claude_op 1
    assert_equals "resolved" "$(_resolve_via_watcher OP_SERVICE_ACCOUNT_TOKEN=tok)" \
        "Service account token: resolves as before"
    assert_file_not_contains "$TEST_TEMP_DIR/op.calls" "whoami" "Token path: no whoami probe"
}

# Helper absent (older image without op-usable.sh): the watcher falls back to
# the original token-only gate — no whoami probe, so an otherwise-usable op is
# not consulted without OP_SERVICE_ACCOUNT_TOKEN.
test_watcher_helper_absent_token_only() {
    _stub_claude_op 0
    assert_equals "skipped" \
        "$(_resolve_via_watcher OP_USABLE_LIB="$TEST_TEMP_DIR/absent-op-usable.sh")" \
        "Helper absent, no token: skip even though op whoami would succeed"
    assert_file_not_exists "$TEST_TEMP_DIR/op.calls" "Helper absent: op never invoked"
    assert_equals "resolved" \
        "$(_resolve_via_watcher OP_USABLE_LIB="$TEST_TEMP_DIR/absent-op-usable.sh" OP_SERVICE_ACCOUNT_TOKEN=tok)" \
        "Helper absent, token set: resolves via the token-only fallback"
    assert_file_not_contains "$TEST_TEMP_DIR/op.calls" "whoami" "Fallback: no whoami probe"
}

# claude-setup is sourced, not executed: its source guard (#1722) returns right
# after is_claude_authenticated, before the plugin library, the setup lock, or
# any setup step. CLAUDE_PLUGIN_LIB points nowhere so a broken guard fails loud
# (exit 1, "required library not found") instead of running a real setup. The
# token file is re-pointed at scratch AFTER sourcing — the real
# /dev/shm/anthropic-auth-token is this container's live token.
_resolve_via_setup() {
    command env -i BASH_ENV= HOME="$TEST_TEMP_DIR/home" \
        PATH="$TEST_TEMP_DIR/bin:/usr/bin:/bin" \
        OP_USABLE_LIB="$PROJECT_ROOT/lib/runtime/lib/op-usable.sh" \
        OP_WHOAMI_CACHE_DIR="$TEST_TEMP_DIR" \
        CONTAINER_CREDENTIAL_ENV_FILE="$TEST_TEMP_DIR/no-credential-env" \
        CLAUDE_PLUGIN_LIB="$TEST_TEMP_DIR/no-plugin-lib.sh" \
        OP_ANTHROPIC_AUTH_TOKEN_REF="op://vault/anthropic/token" \
        "$@" \
        bash -c '. "$1"
                 ANTHROPIC_TOKEN_FILE="$2/anthropic-auth-token"
                 if is_claude_authenticated; then echo resolved; else echo skipped; fi' \
        _ "$CLAUDE_SETUP_BIN" "$TEST_TEMP_DIR" 2>&1
}

test_claude_setup_resolves_with_external_op() {
    _stub_claude_op 0
    assert_equals "resolved" "$(_resolve_via_setup)" \
        "No token in env, op whoami ok: OP_ANTHROPIC_AUTH_TOKEN_REF resolves"
    assert_file_contains "$TEST_TEMP_DIR/anthropic-auth-token" "fake-anthropic-token-1711" \
        "Resolved token is stored (scratch path, never the live one)"
}

test_claude_setup_skips_without_auth() {
    _stub_claude_op 1
    assert_equals "skipped" "$(_resolve_via_setup)" \
        "No token and op whoami fails: skip"
    assert_file_contains "$TEST_TEMP_DIR/op.calls" "whoami" "Gate probed op whoami"
    assert_file_not_contains "$TEST_TEMP_DIR/op.calls" "read" "No op read attempted"
    assert_file_not_exists "$TEST_TEMP_DIR/anthropic-auth-token" "No token stored"
}

test_claude_setup_helper_absent_token_only() {
    _stub_claude_op 0
    assert_equals "skipped" \
        "$(_resolve_via_setup OP_USABLE_LIB="$TEST_TEMP_DIR/absent-op-usable.sh")" \
        "Helper absent, no token: skip even though op whoami would succeed"
    assert_file_not_exists "$TEST_TEMP_DIR/op.calls" "Helper absent: op never invoked"
    assert_equals "resolved" \
        "$(_resolve_via_setup OP_USABLE_LIB="$TEST_TEMP_DIR/absent-op-usable.sh" OP_SERVICE_ACCOUNT_TOKEN=tok)" \
        "Helper absent, token set: resolves via the token-only fallback"
    assert_file_not_contains "$TEST_TEMP_DIR/op.calls" "whoami" "Fallback: no whoami probe"
}

# The guard must NOT fire when claude-setup is executed — directly or via a
# symlink (how it is installed on PATH). Executed with CLAUDE_PLUGIN_LIB
# pointing nowhere, it must get past the guard and fail loud at the library
# check; a guard that misfired would exit 0 silently and skip setup entirely.
test_claude_setup_executed_passes_guard() {
    command ln -s "$CLAUDE_SETUP_BIN" "$TEST_TEMP_DIR/bin/claude-setup"
    local via out rc
    for via in "$CLAUDE_SETUP_BIN" "$TEST_TEMP_DIR/bin/claude-setup"; do
        rc=0
        out=$(command env -i BASH_ENV= HOME="$TEST_TEMP_DIR/home" \
            PATH="$TEST_TEMP_DIR/bin:/usr/bin:/bin" \
            OP_USABLE_LIB="$TEST_TEMP_DIR/absent-op-usable.sh" \
            CLAUDE_PLUGIN_LIB="$TEST_TEMP_DIR/no-plugin-lib.sh" \
            "$via" 2>&1) || rc=$?
        assert_equals "1" "$rc" "Executed via $via: exits 1 at the library check"
        assert_contains "$out" "required library not found: $TEST_TEMP_DIR/no-plugin-lib.sh" \
            "Executed via $via: reached the plugin-library check past the guard"
    done
}

test_claude_setup_no_legacy_token_gate() {
    # Fixed-string match: assert_file_not_contains takes a regex, and the
    # brackets in this line would turn it into a character class.
    if command grep -qF '[ -n "${OP_ANTHROPIC_AUTH_TOKEN_REF:-}" ] && [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]' "$CLAUDE_SETUP_BIN"; then
        fail_test "claude-setup still requires OP_SERVICE_ACCOUNT_TOKEN to resolve the Anthropic ref"
    else
        pass_test "claude-setup no longer requires OP_SERVICE_ACCOUNT_TOKEN"
    fi
}

run_test test_watcher_resolves_with_external_op "#1711: auth-watcher resolves Anthropic ref via externally authenticated op"
run_test test_watcher_skips_without_auth "#1711: auth-watcher skips cleanly with no auth"
run_test test_watcher_token_path_unchanged "#1711: auth-watcher token path unchanged (no whoami)"
run_test test_watcher_helper_absent_token_only "#1722: auth-watcher falls back to token-only gate without op-usable.sh"
run_test test_claude_setup_resolves_with_external_op "#1722: claude-setup resolves Anthropic ref via externally authenticated op"
run_test test_claude_setup_skips_without_auth "#1722: claude-setup skips cleanly with no auth"
run_test test_claude_setup_helper_absent_token_only "#1722: claude-setup falls back to token-only gate without op-usable.sh"
run_test test_claude_setup_executed_passes_guard "#1722: executed claude-setup (direct + symlink) passes the source guard"
run_test test_claude_setup_no_legacy_token_gate "#1711: claude-setup no longer requires OP_SERVICE_ACCOUNT_TOKEN"

generate_report
