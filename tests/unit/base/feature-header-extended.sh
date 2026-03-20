#!/usr/bin/env bash
# Extended unit tests for lib/base/feature-header.sh
# Tests uncovered paths: include guard, create_symlink, create_secure_temp_dir,
# build-env priority, and OS detection exports.

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Feature Header Extended Tests"

# Setup function - runs before each test
setup() {
    export TEST_TEMP_DIR="$RESULTS_DIR/test-feature-header-ext"
    mkdir -p "$TEST_TEMP_DIR"

    # Mock environment variables
    export USERNAME="testuser"
    export USER_UID="1000"
    export USER_GID="1000"
    export HOME="/home/testuser"
    export WORKING_DIR="/workspace/test"

    # Copy feature-header.sh and its sub-modules to the test directory
    command cp "$PROJECT_ROOT/lib/base/feature-header.sh" "$TEST_TEMP_DIR/feature-header-test.sh"
    command cp "$PROJECT_ROOT/lib/base/os-validation.sh" "$TEST_TEMP_DIR/os-validation.sh"
    command cp "$PROJECT_ROOT/lib/base/user-env.sh" "$TEST_TEMP_DIR/user-env.sh"
    command cp "$PROJECT_ROOT/lib/base/arch-utils.sh" "$TEST_TEMP_DIR/arch-utils.sh"
    command cp "$PROJECT_ROOT/lib/base/cleanup-handler.sh" "$TEST_TEMP_DIR/cleanup-handler.sh"
    command cp "$PROJECT_ROOT/lib/base/feature-utils.sh" "$TEST_TEMP_DIR/feature-utils.sh"

    # Copy logging and bashrc sub-modules
    command cp "$PROJECT_ROOT/lib/base/logging.sh" "$TEST_TEMP_DIR/logging.sh"
    command cp "$PROJECT_ROOT/lib/base/feature-logging.sh" "$TEST_TEMP_DIR/feature-logging.sh"
    command cp "$PROJECT_ROOT/lib/base/message-logging.sh" "$TEST_TEMP_DIR/message-logging.sh"
    command cp "$PROJECT_ROOT/lib/base/bashrc-helpers.sh" "$TEST_TEMP_DIR/bashrc-helpers.sh"

    # Patch feature-header to source logging.sh and bashrc-helpers.sh via relative path
    # (original checks /tmp/build-scripts/base/ which doesn't exist in test env)
    command sed -i 's|if \[ -f /tmp/build-scripts/base/logging.sh \]; then|if [ -f "$(dirname "${BASH_SOURCE[0]}")/logging.sh" ]; then|' "$TEST_TEMP_DIR/feature-header-test.sh"
    command sed -i 's|source /tmp/build-scripts/base/logging.sh|source "$(dirname "${BASH_SOURCE[0]}")/logging.sh"|' "$TEST_TEMP_DIR/feature-header-test.sh"
    command sed -i 's|if \[ -f /tmp/build-scripts/base/bashrc-helpers.sh \]; then|if [ -f "$(dirname "${BASH_SOURCE[0]}")/bashrc-helpers.sh" ]; then|' "$TEST_TEMP_DIR/feature-header-test.sh"
    command sed -i 's|source /tmp/build-scripts/base/bashrc-helpers.sh|source "$(dirname "${BASH_SOURCE[0]}")/bashrc-helpers.sh"|' "$TEST_TEMP_DIR/feature-header-test.sh"

    # Pre-source shared dependencies (needed by logging.sh)
    source "$PROJECT_ROOT/lib/shared/export-utils.sh"
    source "$PROJECT_ROOT/lib/shared/logging.sh"
}

# Teardown function - runs after each test
teardown() {
    command rm -rf "$TEST_TEMP_DIR"

    # Unset include guards so re-sourcing works across tests
    unset USERNAME USER_UID USER_GID HOME WORKING_DIR _FEATURE_HEADER_LOADED
    unset _OS_VALIDATION_LOADED _USER_ENV_LOADED _FEATURE_UTILS_LOADED
    unset _ARCH_UTILS_LOADED _CLEANUP_HANDLER_LOADED
    unset _LOGGING_LOADED _SHARED_LOGGING_LOADED _SHARED_EXPORT_UTILS_LOADED
    unset _FEATURE_LOGGING_LOADED _MESSAGE_LOGGING_LOADED
}

# ============================================================================
# Include Guard Tests
# ============================================================================

test_include_guard_prevents_reexecution() {
    # Source once — _FEATURE_HEADER_LOADED should be set
    source "$TEST_TEMP_DIR/feature-header-test.sh"
    assert_equals "1" "$_FEATURE_HEADER_LOADED" "Include guard flag set after first source"

    # Change USERNAME to detect re-execution
    USERNAME="changed-to-detect-resourcing"

    # Source again — the guard should cause an early return, leaving
    # USERNAME at its changed value (not reset to the build-env default)
    source "$TEST_TEMP_DIR/feature-header-test.sh"
    assert_equals "changed-to-detect-resourcing" "$USERNAME" \
        "Include guard prevents re-execution (USERNAME unchanged)"
}

# ============================================================================
# create_symlink Tests
# ============================================================================

test_create_symlink_valid_target() {
    export BUILD_LOG_DIR="$TEST_TEMP_DIR"
    export LOG_LEVEL=DEBUG

    source "$TEST_TEMP_DIR/feature-header-test.sh"

    # Use log_feature_start to properly initialize all logging state
    log_feature_start "SymlinkTest"

    # Create a target file
    local target="$TEST_TEMP_DIR/target-bin"
    echo '#!/bin/bash' > "$target"

    # Create symlink
    local link="$TEST_TEMP_DIR/link-bin"
    create_symlink "$target" "$link" "test binary"

    # Verify link was created
    assert_true [ -L "$link" ] "Symlink was created"

    # Verify target was made executable
    assert_true [ -x "$target" ] "Target is executable"
}

test_create_symlink_missing_target() {
    export BUILD_LOG_DIR="$TEST_TEMP_DIR"
    export LOG_LEVEL=DEBUG

    source "$TEST_TEMP_DIR/feature-header-test.sh"

    log_feature_start "SymlinkMissingTest"

    local link="$TEST_TEMP_DIR/link-missing"
    create_symlink "/nonexistent/target" "$link" "missing target"

    # The warning is logged to CURRENT_LOG_FILE and also to stderr
    if command grep -q "Symlink target does not exist" "$CURRENT_LOG_FILE"; then
        assert_true true "Warning logged for missing target"
    else
        assert_true false "Expected warning for missing target not found in log"
    fi
}

test_create_symlink_missing_arguments() {
    export BUILD_LOG_DIR="$TEST_TEMP_DIR"
    export LOG_LEVEL=DEBUG

    source "$TEST_TEMP_DIR/feature-header-test.sh"

    log_feature_start "SymlinkArgsTest"

    # Call with empty target — should return 1
    local exit_code=0
    create_symlink "" "" 2>/dev/null || exit_code=$?
    assert_not_equals "0" "$exit_code" "create_symlink returns non-zero with missing args"
}

# ============================================================================
# create_secure_temp_dir Tests
# ============================================================================

test_create_secure_temp_dir_returns_valid_dir() {
    export BUILD_LOG_DIR="$TEST_TEMP_DIR"
    export LOG_LEVEL=DEBUG

    source "$TEST_TEMP_DIR/feature-header-test.sh"

    log_feature_start "SecureTempTest"

    local temp_dir
    temp_dir=$(create_secure_temp_dir)

    assert_true [ -d "$temp_dir" ] "create_secure_temp_dir returns existing directory"

    # Check 755 permissions
    local perms
    perms=$(command stat -c '%a' "$temp_dir")
    assert_equals "755" "$perms" "Temp dir has 755 permissions"

    # Note: create_secure_temp_dir runs in a subshell (command substitution),
    # so register_cleanup only affects the subshell's _FEATURE_CLEANUP_ITEMS.
    # Verify that the function itself calls register_cleanup by checking
    # the stderr output contains the registration message.
    local output
    output=$(create_secure_temp_dir 2>&1 >/dev/null)
    if echo "$output" | command grep -q "Registered for cleanup"; then
        assert_true true "Temp dir registered for cleanup"
    else
        assert_true false "Temp dir not registered for cleanup"
    fi

    # Clean up
    command rm -rf "$temp_dir"
}

# ============================================================================
# build-env Priority Tests
# ============================================================================

test_build_env_uid_priority() {
    # Unset guards and user vars so re-sourcing processes them
    unset _FEATURE_HEADER_LOADED _OS_VALIDATION_LOADED _USER_ENV_LOADED _FEATURE_UTILS_LOADED
    unset _ARCH_UTILS_LOADED _CLEANUP_HANDLER_LOADED

    # Create a mock /tmp/build-env with a custom UID
    local mock_build_env="$TEST_TEMP_DIR/mock-build-env"
    command cat > "$mock_build_env" << 'ENVEOF'
ACTUAL_UID=1234
ACTUAL_GID=5678
USERNAME=testuser
WORKING_DIR=/workspace/test
ENVEOF

    # Patch user-env.sh (where build-env sourcing now lives) to use our mock
    command sed -i "s|/tmp/build-env|${mock_build_env}|g" "$TEST_TEMP_DIR/user-env.sh"

    # Unset to let feature-header set them from build-env
    unset USER_UID USER_GID

    source "$TEST_TEMP_DIR/feature-header-test.sh"

    assert_equals "1234" "$USER_UID" "USER_UID set from build-env ACTUAL_UID"
    assert_equals "5678" "$USER_GID" "USER_GID set from build-env ACTUAL_GID"
}

# ============================================================================
# OS Detection Tests
# ============================================================================

test_debian_version_exported() {
    # This test validates that DEBIAN_VERSION or UBUNTU_VERSION is exported
    # after sourcing the feature header (depends on the host OS)
    source "$TEST_TEMP_DIR/feature-header-test.sh"

    if [ -n "${DEBIAN_VERSION:-}" ]; then
        assert_not_empty "$DEBIAN_VERSION" "DEBIAN_VERSION is exported"
    elif [ -n "${UBUNTU_VERSION:-}" ]; then
        assert_not_empty "$UBUNTU_VERSION" "UBUNTU_VERSION is exported"
    else
        # In a non-Debian/Ubuntu test environment, the script would have
        # exited early. If we got here, one of them must be set.
        assert_true false "Neither DEBIAN_VERSION nor UBUNTU_VERSION is set"
    fi
}

# Run tests with setup/teardown
run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"

    setup
    run_test "$test_function" "$test_description"
    teardown
}

# Run all tests
run_test_with_setup test_include_guard_prevents_reexecution "Include guard prevents re-execution"
run_test_with_setup test_create_symlink_valid_target "create_symlink with valid target creates link"
run_test_with_setup test_create_symlink_missing_target "create_symlink with missing target logs warning"
run_test_with_setup test_create_symlink_missing_arguments "create_symlink with missing args returns 1"
run_test_with_setup test_create_secure_temp_dir_returns_valid_dir "create_secure_temp_dir returns valid dir with 755 perms"
run_test_with_setup test_build_env_uid_priority "build-env ACTUAL_UID takes priority over defaults"
run_test_with_setup test_debian_version_exported "DEBIAN_VERSION or UBUNTU_VERSION is exported"

# Generate test report
generate_report
