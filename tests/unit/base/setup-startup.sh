#!/usr/bin/env bash
# Unit tests for lib/base/setup-startup.sh
# Verifies that the script creates the expected directory structure under
# /etc/container and /etc/healthcheck.d with 755 permissions, and that
# it emits the expected output banners.

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Setup Startup Tests"

# Absolute path to the source script under test
SOURCE_SCRIPT="$PROJECT_ROOT/lib/base/setup-startup.sh"

# Setup function - runs before each test.
# Creates a temp dir and a patched copy of the script that writes to
# TEST_TEMP_DIR/etc/ instead of /etc/ so tests can run without root.
setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$RESULTS_DIR/test-setup-startup-$unique_id"
    mkdir -p "$TEST_TEMP_DIR"

    # Build a patched copy: replace every /etc/ reference with the sandbox path
    export PATCHED_SCRIPT="$TEST_TEMP_DIR/setup-startup-patched.sh"
    command sed "s|/etc/|$TEST_TEMP_DIR/etc/|g" "$SOURCE_SCRIPT" > "$PATCHED_SCRIPT"
    chmod +x "$PATCHED_SCRIPT"
}

# Teardown function - runs after each test
teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
    unset PATCHED_SCRIPT 2>/dev/null || true
}

# Run tests with setup/teardown
run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"
    setup
    run_test "$test_function" "$test_description"
    teardown
}

# ---------------------------------------------------------------------------
# Test: source script exists and is executable
# ---------------------------------------------------------------------------
test_source_script_is_executable() {
    assert_file_exists "$SOURCE_SCRIPT" \
        "lib/base/setup-startup.sh should exist"
    assert_executable "$SOURCE_SCRIPT" \
        "lib/base/setup-startup.sh should be executable"
}

# ---------------------------------------------------------------------------
# Test: /etc/container/first-startup is created
# ---------------------------------------------------------------------------
test_creates_first_startup_directory() {
    bash "$PATCHED_SCRIPT" >/dev/null 2>&1
    assert_dir_exists "$TEST_TEMP_DIR/etc/container/first-startup" \
        "first-startup directory should be created"
}

# ---------------------------------------------------------------------------
# Test: /etc/container/startup is created
# ---------------------------------------------------------------------------
test_creates_startup_directory() {
    bash "$PATCHED_SCRIPT" >/dev/null 2>&1
    assert_dir_exists "$TEST_TEMP_DIR/etc/container/startup" \
        "startup directory should be created"
}

# ---------------------------------------------------------------------------
# Test: /etc/healthcheck.d is created
# ---------------------------------------------------------------------------
test_creates_healthcheck_directory() {
    bash "$PATCHED_SCRIPT" >/dev/null 2>&1
    assert_dir_exists "$TEST_TEMP_DIR/etc/healthcheck.d" \
        "healthcheck.d directory should be created"
}

# ---------------------------------------------------------------------------
# Test: all four directories have 755 permissions
# ---------------------------------------------------------------------------
test_directories_have_755_permissions() {
    bash "$PATCHED_SCRIPT" >/dev/null 2>&1

    local dirs=(
        "$TEST_TEMP_DIR/etc/container"
        "$TEST_TEMP_DIR/etc/container/first-startup"
        "$TEST_TEMP_DIR/etc/container/startup"
        "$TEST_TEMP_DIR/etc/healthcheck.d"
    )

    for dir in "${dirs[@]}"; do
        local perms
        perms=$(/usr/bin/stat -c '%a' "$dir" 2>/dev/null)
        assert_equals "755" "$perms" \
            "Directory $dir should have 755 permissions (got: $perms)"
    done
}

# ---------------------------------------------------------------------------
# Test: script outputs the setup banner
# ---------------------------------------------------------------------------
test_outputs_setup_banner() {
    local output
    output=$(bash "$PATCHED_SCRIPT" 2>&1)
    assert_contains "$output" "=== Setting up startup script system ===" \
        "Output should contain setup banner"
}

# ---------------------------------------------------------------------------
# Test: script outputs the configured banner
# ---------------------------------------------------------------------------
test_outputs_configured_banner() {
    local output
    output=$(bash "$PATCHED_SCRIPT" 2>&1)
    assert_contains "$output" "=== Startup system configured ===" \
        "Output should contain configured banner"
}

# ---------------------------------------------------------------------------
# Test: script is idempotent — running twice does not fail
# ---------------------------------------------------------------------------
test_idempotent_second_run_succeeds() {
    local exit_code=0
    bash "$PATCHED_SCRIPT" >/dev/null 2>&1
    bash "$PATCHED_SCRIPT" >/dev/null 2>&1 || exit_code=$?
    assert_equals "0" "$exit_code" \
        "Second run of script should exit 0 (idempotent)"
}

# ---------------------------------------------------------------------------
# Test: directories still have 755 permissions after second run
# ---------------------------------------------------------------------------
test_idempotent_permissions_preserved() {
    bash "$PATCHED_SCRIPT" >/dev/null 2>&1
    # Alter one permission, then re-run; the script should restore it
    chmod 700 "$TEST_TEMP_DIR/etc/container/startup"
    bash "$PATCHED_SCRIPT" >/dev/null 2>&1

    local perms
    perms=$(/usr/bin/stat -c '%a' "$TEST_TEMP_DIR/etc/container/startup" 2>/dev/null)
    assert_equals "755" "$perms" \
        "Permissions should be restored to 755 on second run"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
run_test_with_setup test_source_script_is_executable \
    "Source script exists and is executable"

run_test_with_setup test_creates_first_startup_directory \
    "Creates /etc/container/first-startup directory"

run_test_with_setup test_creates_startup_directory \
    "Creates /etc/container/startup directory"

run_test_with_setup test_creates_healthcheck_directory \
    "Creates /etc/healthcheck.d directory"

run_test_with_setup test_directories_have_755_permissions \
    "All directories have 755 permissions"

run_test_with_setup test_outputs_setup_banner \
    "Outputs setup banner"

run_test_with_setup test_outputs_configured_banner \
    "Outputs configured banner"

run_test_with_setup test_idempotent_second_run_succeeds \
    "Idempotent — second run exits 0"

run_test_with_setup test_idempotent_permissions_preserved \
    "Idempotent — permissions restored on second run"

# Generate test report
generate_report
