#!/usr/bin/env bash
# Unit tests for lib/runtime/secrets/docker-secrets.sh
# Tests Docker secrets integration functionality

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Docker Secrets Integration Tests"

# Source file under test
SOURCE_FILE="$PROJECT_ROOT/lib/runtime/secrets/docker-secrets.sh"

# Setup function - runs before each test
setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$RESULTS_DIR/test-docker-secrets-$unique_id"
    mkdir -p "$TEST_TEMP_DIR"

    # Create mock secrets directory
    export DOCKER_SECRETS_DIR="$TEST_TEMP_DIR/run/secrets"
    mkdir -p "$DOCKER_SECRETS_DIR"
}

# Teardown function - runs after each test
teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
    unset DOCKER_SECRETS_DIR DOCKER_SECRETS_ENABLED DOCKER_SECRET_PREFIX \
          DOCKER_SECRET_NAMES DOCKER_SECRETS_UPPERCASE TEST_TEMP_DIR 2>/dev/null || true
}

# Run tests with setup/teardown
run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"
    setup
    run_test "$test_function" "$test_description"
    teardown
}

# Helper: run a subshell that sources the file and outputs result on last line
# All log output is suppressed (sent to /dev/null)
_run_secrets_subshell() {
    # Runs the provided commands in a subshell, suppressing all log output
    # Usage: result=$(_run_secrets_subshell "commands...")
    bash -c "
        source '$SOURCE_FILE' >/dev/null 2>&1
        $1
    " 2>/dev/null
}

# ============================================================================
# Static Analysis Tests
# ============================================================================

test_strict_mode() {
    assert_file_contains "$SOURCE_FILE" "set -euo pipefail" "Script uses strict mode"
}

test_defines_docker_secrets_available() {
    assert_file_contains "$SOURCE_FILE" "docker_secrets_available()" \
        "Script defines docker_secrets_available function"
}

test_defines_load_secrets_from_docker() {
    assert_file_contains "$SOURCE_FILE" "load_secrets_from_docker()" \
        "Script defines load_secrets_from_docker function"
}

test_defines_health_check() {
    assert_file_contains "$SOURCE_FILE" "docker_secrets_health_check()" \
        "Script defines docker_secrets_health_check function"
}

test_sources_common_sh() {
    assert_file_contains "$SOURCE_FILE" 'common\.sh' \
        "Script sources common.sh for logging and helpers"
}

test_default_secrets_dir() {
    assert_file_contains "$SOURCE_FILE" '/run/secrets' \
        "Script uses /run/secrets as default directory"
}

# ============================================================================
# Functional Tests - docker_secrets_available()
# ============================================================================

test_available_when_secrets_exist() {
    echo "test-secret-value" > "$DOCKER_SECRETS_DIR/my-secret"

    local result
    result=$(_run_secrets_subshell "
        export DOCKER_SECRETS_DIR='$DOCKER_SECRETS_DIR'
        docker_secrets_available && echo AVAILABLE || echo NOT_AVAILABLE
    ")

    assert_equals "AVAILABLE" "$result" "Secrets should be available when files exist"
}

test_not_available_when_dir_empty() {
    local result
    result=$(_run_secrets_subshell "
        export DOCKER_SECRETS_DIR='$DOCKER_SECRETS_DIR'
        docker_secrets_available && echo AVAILABLE || echo NOT_AVAILABLE
    ")

    assert_equals "NOT_AVAILABLE" "$result" "Secrets should not be available when dir is empty"
}

test_not_available_when_dir_missing() {
    local result
    result=$(_run_secrets_subshell "
        export DOCKER_SECRETS_DIR='$TEST_TEMP_DIR/nonexistent'
        docker_secrets_available && echo AVAILABLE || echo NOT_AVAILABLE
    ")

    assert_equals "NOT_AVAILABLE" "$result" "Secrets should not be available when dir missing"
}

# ============================================================================
# Functional Tests - load_secrets_from_docker()
# ============================================================================

test_load_secrets_exports_env_vars() {
    echo "my-db-password" > "$DOCKER_SECRETS_DIR/db-password"

    local result
    result=$(_run_secrets_subshell "
        export DOCKER_SECRETS_DIR='$DOCKER_SECRETS_DIR'
        export DOCKER_SECRETS_ENABLED='true'
        load_secrets_from_docker >/dev/null 2>&1
        echo \"\${DB_PASSWORD:-UNSET}\"
    ")

    assert_equals "my-db-password" "$result" "Secret should be exported as env var"
}

test_load_secrets_uppercase_conversion() {
    echo "value123" > "$DOCKER_SECRETS_DIR/api-key"

    local result
    result=$(_run_secrets_subshell "
        export DOCKER_SECRETS_DIR='$DOCKER_SECRETS_DIR'
        export DOCKER_SECRETS_ENABLED='true'
        export DOCKER_SECRETS_UPPERCASE='true'
        load_secrets_from_docker >/dev/null 2>&1
        echo \"\${API_KEY:-UNSET}\"
    ")

    assert_equals "value123" "$result" "Secret name should be converted to uppercase"
}

test_load_secrets_hyphens_to_underscores() {
    echo "secret-value" > "$DOCKER_SECRETS_DIR/my-app-token"

    local result
    result=$(_run_secrets_subshell "
        export DOCKER_SECRETS_DIR='$DOCKER_SECRETS_DIR'
        export DOCKER_SECRETS_ENABLED='true'
        export DOCKER_SECRETS_UPPERCASE='true'
        load_secrets_from_docker >/dev/null 2>&1
        echo \"\${MY_APP_TOKEN:-UNSET}\"
    ")

    assert_equals "secret-value" "$result" "Hyphens should be converted to underscores"
}

test_load_secrets_skips_hidden_files() {
    echo "visible" > "$DOCKER_SECRETS_DIR/visible-secret"
    echo "hidden" > "$DOCKER_SECRETS_DIR/.hidden-secret"

    local result
    result=$(_run_secrets_subshell "
        export DOCKER_SECRETS_DIR='$DOCKER_SECRETS_DIR'
        export DOCKER_SECRETS_ENABLED='true'
        load_secrets_from_docker >/dev/null 2>&1
        echo \"visible=\${VISIBLE_SECRET:-UNSET}\"
        echo \"hidden=\${HIDDEN_SECRET:-UNSET}\"
    ")

    assert_contains "$result" "visible=visible" "Visible secret should be loaded"
    assert_contains "$result" "hidden=UNSET" "Hidden file should be skipped"
}

test_load_secrets_skips_empty_files() {
    touch "$DOCKER_SECRETS_DIR/empty-secret"
    echo "has-value" > "$DOCKER_SECRETS_DIR/real-secret"

    local result
    result=$(_run_secrets_subshell "
        export DOCKER_SECRETS_DIR='$DOCKER_SECRETS_DIR'
        export DOCKER_SECRETS_ENABLED='true'
        load_secrets_from_docker >/dev/null 2>&1
        echo \"empty=\${EMPTY_SECRET:-UNSET}\"
        echo \"real=\${REAL_SECRET:-UNSET}\"
    ")

    assert_contains "$result" "empty=UNSET" "Empty secret should be skipped"
    assert_contains "$result" "real=has-value" "Non-empty secret should be loaded"
}

test_load_secrets_with_prefix() {
    echo "token123" > "$DOCKER_SECRETS_DIR/api-key"

    local result
    result=$(_run_secrets_subshell "
        export DOCKER_SECRETS_DIR='$DOCKER_SECRETS_DIR'
        export DOCKER_SECRETS_ENABLED='true'
        export DOCKER_SECRET_PREFIX='APP_'
        load_secrets_from_docker >/dev/null 2>&1
        echo \"\${APP_API_KEY:-UNSET}\"
    ")

    assert_equals "token123" "$result" "Secret should have prefix applied"
}

test_load_secrets_specific_names() {
    echo "value1" > "$DOCKER_SECRETS_DIR/secret-a"
    echo "value2" > "$DOCKER_SECRETS_DIR/secret-b"
    echo "value3" > "$DOCKER_SECRETS_DIR/secret-c"

    local result
    result=$(_run_secrets_subshell "
        export DOCKER_SECRETS_DIR='$DOCKER_SECRETS_DIR'
        export DOCKER_SECRETS_ENABLED='true'
        export DOCKER_SECRET_NAMES='secret-a,secret-c'
        load_secrets_from_docker >/dev/null 2>&1
        echo \"a=\${SECRET_A:-UNSET}\"
        echo \"b=\${SECRET_B:-UNSET}\"
        echo \"c=\${SECRET_C:-UNSET}\"
    ")

    assert_contains "$result" "a=value1" "Requested secret-a should be loaded"
    assert_contains "$result" "b=UNSET" "Non-requested secret-b should not be loaded"
    assert_contains "$result" "c=value3" "Requested secret-c should be loaded"
}

test_load_secrets_no_uppercase() {
    echo "myval" > "$DOCKER_SECRETS_DIR/mykey"

    local result
    result=$(_run_secrets_subshell "
        export DOCKER_SECRETS_DIR='$DOCKER_SECRETS_DIR'
        export DOCKER_SECRETS_ENABLED='true'
        export DOCKER_SECRETS_UPPERCASE='false'
        load_secrets_from_docker >/dev/null 2>&1
        echo \"\${mykey:-UNSET}\"
    ")

    assert_equals "myval" "$result" "Secret name should stay lowercase when uppercase disabled"
}

test_dots_converted_to_underscores() {
    echo "dotval" > "$DOCKER_SECRETS_DIR/app.config.key"

    local result
    result=$(_run_secrets_subshell "
        export DOCKER_SECRETS_DIR='$DOCKER_SECRETS_DIR'
        export DOCKER_SECRETS_ENABLED='true'
        load_secrets_from_docker >/dev/null 2>&1
        echo \"\${APP_CONFIG_KEY:-UNSET}\"
    ")

    assert_equals "dotval" "$result" "Dots in secret names should become underscores"
}

# ============================================================================
# Functional Tests - DOCKER_SECRETS_ENABLED toggle
# ============================================================================

test_disabled_explicitly() {
    echo "secret" > "$DOCKER_SECRETS_DIR/test-secret"

    local result
    result=$(_run_secrets_subshell "
        export DOCKER_SECRETS_DIR='$DOCKER_SECRETS_DIR'
        export DOCKER_SECRETS_ENABLED='false'
        load_secrets_from_docker >/dev/null 2>&1
        echo \"\${TEST_SECRET:-UNSET}\"
    ")

    assert_equals "UNSET" "$result" "Secrets should not load when explicitly disabled"
}

test_auto_detect_with_secrets() {
    echo "auto-value" > "$DOCKER_SECRETS_DIR/auto-secret"

    local result
    result=$(_run_secrets_subshell "
        export DOCKER_SECRETS_DIR='$DOCKER_SECRETS_DIR'
        export DOCKER_SECRETS_ENABLED='auto'
        load_secrets_from_docker >/dev/null 2>&1
        echo \"\${AUTO_SECRET:-UNSET}\"
    ")

    assert_equals "auto-value" "$result" "Auto mode should load when secrets present"
}

test_auto_detect_without_secrets() {
    local exit_code=0
    _run_secrets_subshell "
        export DOCKER_SECRETS_DIR='$DOCKER_SECRETS_DIR'
        export DOCKER_SECRETS_ENABLED='auto'
        load_secrets_from_docker >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "0" "$exit_code" "Auto mode should return 0 when no secrets present"
}

# ============================================================================
# Functional Tests - Error handling
# ============================================================================

test_returns_error_for_nonexistent_dir() {
    local exit_code=0
    _run_secrets_subshell "
        export DOCKER_SECRETS_ENABLED='true'
        export DOCKER_SECRETS_DIR='$TEST_TEMP_DIR/nonexistent'
        load_secrets_from_docker >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "1" "$exit_code" "Should return 1 for non-existent directory"
}

test_returns_zero_for_successful_load() {
    echo "value" > "$DOCKER_SECRETS_DIR/test"

    local exit_code=0
    _run_secrets_subshell "
        export DOCKER_SECRETS_DIR='$DOCKER_SECRETS_DIR'
        export DOCKER_SECRETS_ENABLED='true'
        load_secrets_from_docker >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "0" "$exit_code" "Should return 0 on successful load"
}

# ============================================================================
# Functional Tests - Health Check
# ============================================================================

test_health_check_when_secrets_available() {
    echo "secret" > "$DOCKER_SECRETS_DIR/test"

    local exit_code=0
    _run_secrets_subshell "
        export DOCKER_SECRETS_DIR='$DOCKER_SECRETS_DIR'
        docker_secrets_health_check >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "0" "$exit_code" "Health check should pass when secrets exist"
}

test_health_check_when_no_secrets() {
    local exit_code=0
    _run_secrets_subshell "
        export DOCKER_SECRETS_DIR='$DOCKER_SECRETS_DIR'
        docker_secrets_health_check >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "1" "$exit_code" "Health check should fail when no secrets"
}

test_health_check_when_disabled() {
    local exit_code=0
    _run_secrets_subshell "
        export DOCKER_SECRETS_ENABLED='false'
        docker_secrets_health_check >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "0" "$exit_code" "Health check should pass when disabled"
}

# ============================================================================
# Run all tests
# ============================================================================

# Static analysis
run_test_with_setup test_strict_mode "Script uses strict mode"
run_test_with_setup test_defines_docker_secrets_available "Defines docker_secrets_available function"
run_test_with_setup test_defines_load_secrets_from_docker "Defines load_secrets_from_docker function"
run_test_with_setup test_defines_health_check "Defines health check function"
run_test_with_setup test_sources_common_sh "Sources common.sh for logging and helpers"
run_test_with_setup test_default_secrets_dir "Uses /run/secrets as default"

# Availability detection
run_test_with_setup test_available_when_secrets_exist "Secrets available when files exist"
run_test_with_setup test_not_available_when_dir_empty "Secrets not available when directory empty"
run_test_with_setup test_not_available_when_dir_missing "Secrets not available when directory missing"

# Secret loading
run_test_with_setup test_load_secrets_exports_env_vars "Loads and exports secrets as env vars"
run_test_with_setup test_load_secrets_uppercase_conversion "Converts names to uppercase"
run_test_with_setup test_load_secrets_hyphens_to_underscores "Converts hyphens to underscores"
run_test_with_setup test_load_secrets_skips_hidden_files "Skips hidden files"
run_test_with_setup test_load_secrets_skips_empty_files "Skips empty secret files"
run_test_with_setup test_load_secrets_with_prefix "Applies prefix to env var names"
run_test_with_setup test_load_secrets_specific_names "Loads only specific named secrets"
run_test_with_setup test_load_secrets_no_uppercase "Respects uppercase=false setting"
run_test_with_setup test_dots_converted_to_underscores "Converts dots to underscores"

# Enable/disable toggle
run_test_with_setup test_disabled_explicitly "Disabled when DOCKER_SECRETS_ENABLED=false"
run_test_with_setup test_auto_detect_with_secrets "Auto-detect loads when secrets present"
run_test_with_setup test_auto_detect_without_secrets "Auto-detect returns 0 when no secrets"

# Error handling
run_test_with_setup test_returns_error_for_nonexistent_dir "Returns error for non-existent directory"
run_test_with_setup test_returns_zero_for_successful_load "Returns 0 on successful load"

# Health check
run_test_with_setup test_health_check_when_secrets_available "Health check passes with secrets"
run_test_with_setup test_health_check_when_no_secrets "Health check fails without secrets"
run_test_with_setup test_health_check_when_disabled "Health check passes when disabled"

# Generate test report
generate_report
