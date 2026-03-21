#!/usr/bin/env bash
# Exported-symbol smoke tests for feature-header.sh and feature-header-bootstrap.sh
# Validates that each header exports exactly the expected set of functions.

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Feature Header Symbol Tests"

# Setup function - runs before each test
setup() {
    export TEST_TEMP_DIR="$RESULTS_DIR/test-feature-header-symbols"
    mkdir -p "$TEST_TEMP_DIR"

    # Mock environment variables
    export USERNAME="testuser"
    export USER_UID="1000"
    export USER_GID="1000"
    export HOME="/home/testuser"
    export WORKING_DIR="/workspace/test"

    # Copy all sub-modules to test directory
    command cp "$PROJECT_ROOT/lib/base/feature-header.sh" "$TEST_TEMP_DIR/feature-header-test.sh"
    command cp "$PROJECT_ROOT/lib/base/feature-header-bootstrap.sh" "$TEST_TEMP_DIR/feature-header-bootstrap.sh"
    command cp "$PROJECT_ROOT/lib/base/os-validation.sh" "$TEST_TEMP_DIR/os-validation.sh"
    command cp "$PROJECT_ROOT/lib/base/debian-version.sh" "$TEST_TEMP_DIR/debian-version.sh"
    command cp "$PROJECT_ROOT/lib/base/user-env.sh" "$TEST_TEMP_DIR/user-env.sh"
    command cp "$PROJECT_ROOT/lib/base/arch-utils.sh" "$TEST_TEMP_DIR/arch-utils.sh"
    command cp "$PROJECT_ROOT/lib/base/cleanup-handler.sh" "$TEST_TEMP_DIR/cleanup-handler.sh"
    command cp "$PROJECT_ROOT/lib/base/feature-utils.sh" "$TEST_TEMP_DIR/feature-utils.sh"
    command cp "$PROJECT_ROOT/lib/base/logging.sh" "$TEST_TEMP_DIR/logging.sh"
    command cp "$PROJECT_ROOT/lib/base/feature-logging.sh" "$TEST_TEMP_DIR/feature-logging.sh"
    command cp "$PROJECT_ROOT/lib/base/message-logging.sh" "$TEST_TEMP_DIR/message-logging.sh"
    command cp "$PROJECT_ROOT/lib/base/bashrc-helpers.sh" "$TEST_TEMP_DIR/bashrc-helpers.sh"

    # Patch feature-header-test.sh to resolve bootstrap via relative path
    command sed -i 's|/tmp/build-scripts/base/feature-header-bootstrap.sh|'"$TEST_TEMP_DIR"'/feature-header-bootstrap.sh|g' "$TEST_TEMP_DIR/feature-header-test.sh"

    # Patch feature-header-bootstrap.sh to resolve sub-modules via relative path
    command sed -i 's|if \[ -f /tmp/build-scripts/base/logging.sh \]; then|if [ -f "$(dirname "${BASH_SOURCE[0]}")/logging.sh" ]; then|' "$TEST_TEMP_DIR/feature-header-bootstrap.sh"
    command sed -i 's|source /tmp/build-scripts/base/logging.sh|source "$(dirname "${BASH_SOURCE[0]}")/logging.sh"|' "$TEST_TEMP_DIR/feature-header-bootstrap.sh"
    command sed -i 's|if \[ -f /tmp/build-scripts/base/bashrc-helpers.sh \]; then|if [ -f "$(dirname "${BASH_SOURCE[0]}")/bashrc-helpers.sh" ]; then|' "$TEST_TEMP_DIR/feature-header-bootstrap.sh"
    command sed -i 's|source /tmp/build-scripts/base/bashrc-helpers.sh|source "$(dirname "${BASH_SOURCE[0]}")/bashrc-helpers.sh"|' "$TEST_TEMP_DIR/feature-header-bootstrap.sh"

    # Pre-source shared dependencies (needed by logging.sh)
    source "$PROJECT_ROOT/lib/shared/export-utils.sh"
    source "$PROJECT_ROOT/lib/shared/logging.sh"
}

# Teardown function - runs after each test
teardown() {
    command rm -rf "$TEST_TEMP_DIR"

    # Unset include guards so re-sourcing works across tests
    unset USERNAME USER_UID USER_GID HOME WORKING_DIR
    unset _FEATURE_HEADER_LOADED _FEATURE_HEADER_BOOTSTRAP_LOADED
    unset _OS_VALIDATION_LOADED _DEBIAN_VERSION_LOADED _USER_ENV_LOADED _FEATURE_UTILS_LOADED
    unset _ARCH_UTILS_LOADED _CLEANUP_HANDLER_LOADED
    unset _LOGGING_LOADED _SHARED_LOGGING_LOADED _SHARED_EXPORT_UTILS_LOADED
    unset _FEATURE_LOGGING_LOADED _MESSAGE_LOGGING_LOADED

    # Reset traps before unsetting functions they reference
    trap - EXIT INT TERM HUP 2>/dev/null || true

    # Unset optional-module functions to prevent leakage across tests
    unset -f map_arch map_arch_or_skip
    unset -f create_symlink create_secure_temp_dir
    unset -f register_cleanup unregister_cleanup cleanup_on_interrupt
}

# ============================================================================
# Full Header Symbol Tests
# ============================================================================

test_full_header_defines_all_functions() {
    source "$TEST_TEMP_DIR/feature-header-test.sh"

    # Bootstrap functions
    local bootstrap_functions=(
        log_message log_error log_warning log_feature_start
        log_command log_feature_end log_feature_summary
        write_bashrc_content
    )

    for fn in "${bootstrap_functions[@]}"; do
        if [ "$(type -t "$fn")" = "function" ]; then
            assert_true true "$fn defined by full header"
        else
            assert_true false "$fn NOT defined by full header"
        fi
    done

    # Optional-module functions
    local optional_functions=(
        map_arch map_arch_or_skip
        create_symlink create_secure_temp_dir
        register_cleanup unregister_cleanup cleanup_on_interrupt
    )

    for fn in "${optional_functions[@]}"; do
        if [ "$(type -t "$fn")" = "function" ]; then
            assert_true true "$fn defined by full header"
        else
            assert_true false "$fn NOT defined by full header"
        fi
    done
}

# ============================================================================
# Bootstrap-Only Symbol Tests
# ============================================================================

test_bootstrap_defines_core_functions() {
    source "$TEST_TEMP_DIR/feature-header-bootstrap.sh"

    local expected_functions=(
        log_message log_error log_warning log_feature_start
        log_command log_feature_end log_feature_summary
        write_bashrc_content
    )

    for fn in "${expected_functions[@]}"; do
        if [ "$(type -t "$fn")" = "function" ]; then
            assert_true true "$fn defined by bootstrap"
        else
            assert_true false "$fn NOT defined by bootstrap"
        fi
    done
}

test_bootstrap_does_not_define_optional_functions() {
    source "$TEST_TEMP_DIR/feature-header-bootstrap.sh"

    local optional_functions=(
        map_arch map_arch_or_skip
        create_symlink create_secure_temp_dir
        register_cleanup unregister_cleanup cleanup_on_interrupt
    )

    for fn in "${optional_functions[@]}"; do
        if [ "$(type -t "$fn")" = "function" ]; then
            assert_true false "$fn should NOT be defined by bootstrap-only"
        else
            assert_true true "$fn correctly absent from bootstrap"
        fi
    done
}

# ============================================================================
# Composability Tests
# ============================================================================

test_bootstrap_then_full_header_no_double_execution() {
    # Source bootstrap first
    source "$TEST_TEMP_DIR/feature-header-bootstrap.sh"
    assert_equals "1" "$_FEATURE_HEADER_BOOTSTRAP_LOADED" \
        "Bootstrap guard set after first source"

    # Source full header — should work without conflict
    source "$TEST_TEMP_DIR/feature-header-test.sh"
    assert_equals "1" "$_FEATURE_HEADER_LOADED" \
        "Full header guard set after second source"

    # Bootstrap guard should still be set (not reset)
    assert_equals "1" "$_FEATURE_HEADER_BOOTSTRAP_LOADED" \
        "Bootstrap guard still set after full header"

    # All functions from both layers should be available
    assert_true [ "$(type -t log_message)" = "function" ] \
        "log_message available after composing both headers"
    assert_true [ "$(type -t map_arch)" = "function" ] \
        "map_arch available after composing both headers"
    assert_true [ "$(type -t create_symlink)" = "function" ] \
        "create_symlink available after composing both headers"
}

test_full_header_then_bootstrap_is_noop() {
    # Source full header first
    source "$TEST_TEMP_DIR/feature-header-test.sh"

    # Change USERNAME to detect re-execution
    USERNAME="sentinel-value"

    # Source bootstrap — should be a no-op (bootstrap guard already set)
    source "$TEST_TEMP_DIR/feature-header-bootstrap.sh"

    assert_equals "sentinel-value" "$USERNAME" \
        "Bootstrap is no-op when already loaded via full header"
}

# Run tests with setup/teardown
run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"

    setup
    run_test "$test_function" "$test_description"
    teardown
}

# Run all tests (bootstrap tests first to avoid function leakage)
run_test_with_setup test_bootstrap_defines_core_functions \
    "Bootstrap defines core functions"
run_test_with_setup test_bootstrap_does_not_define_optional_functions \
    "Bootstrap does not define optional-module functions"
run_test_with_setup test_full_header_defines_all_functions \
    "Full header defines all expected functions"
run_test_with_setup test_bootstrap_then_full_header_no_double_execution \
    "Bootstrap then full header composes without double execution"
run_test_with_setup test_full_header_then_bootstrap_is_noop \
    "Full header then bootstrap is a no-op"

# Generate test report
generate_report
