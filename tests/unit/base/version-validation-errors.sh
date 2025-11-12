#!/usr/bin/env bash
# Unit tests for version validation error messages
# Tests that validation functions produce helpful error messages for invalid inputs

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Version Validation Error Message Tests"

# Setup function - runs before each test
setup() {
    # Create temporary directory for testing
    export TEST_TEMP_DIR="$RESULTS_DIR/test-version-validation-errors"
    mkdir -p "$TEST_TEMP_DIR"

    # Create the /tmp/build-scripts/base directory structure (where version-validation.sh expects it)
    mkdir -p /tmp/build-scripts/base

    # Create a minimal logging.sh stub that captures error messages
    cat > /tmp/build-scripts/base/logging.sh << 'EOF'
#!/bin/bash
# Stub logging functions for testing
log_error() {
    echo "ERROR: $*" >&2
}
log_warning() {
    echo "WARNING: $*" >&2
}
log_message() {
    echo "INFO: $*"
}
EOF

    # Source the actual validation script from its location
    source "$CONTAINERS_DIR/lib/base/version-validation.sh"
}

# Teardown function - runs after each test
teardown() {
    # Clean up test directory
    if [ -n "${TEST_TEMP_DIR:-}" ] && [ -d "$TEST_TEMP_DIR" ]; then
        rm -rf "$TEST_TEMP_DIR"
    fi

    # Clean up the logging.sh stub
    rm -f /tmp/build-scripts/base/logging.sh

    # Unset test variables
    unset TEST_TEMP_DIR 2>/dev/null || true
}

# ============================================================================
# Tests for validate_semver - strict X.Y.Z format
# ============================================================================

test_semver_empty_string() {
    local output
    output=$(validate_semver "" "TEST_VERSION" 2>&1 || true)

    assert_contains "$output" "Empty TEST_VERSION provided" \
        "Empty version produces error message"

    # Verify function returns error code
    if validate_semver "" "TEST_VERSION" 2>/dev/null; then
        fail_test "validate_semver should fail for empty string"
    fi
}

test_semver_invalid_format_missing_patch() {
    local output
    output=$(validate_semver "1.2" "TEST_VERSION" 2>&1 || true)

    assert_contains "$output" "Invalid TEST_VERSION format: 1.2" \
        "Missing patch version produces error message"
    assert_contains "$output" "Expected format: X.Y.Z" \
        "Error message includes expected format"

    if validate_semver "1.2" "TEST_VERSION" 2>/dev/null; then
        fail_test "validate_semver should fail for X.Y format"
    fi
}

test_semver_invalid_format_with_alpha() {
    local output
    output=$(validate_semver "1.2.3-alpha" "TEST_VERSION" 2>&1 || true)

    assert_contains "$output" "Invalid TEST_VERSION format: 1.2.3-alpha" \
        "Alpha suffix produces error message"
    assert_contains "$output" "Only digits and dots allowed" \
        "Error message warns about allowed characters"

    if validate_semver "1.2.3-alpha" "TEST_VERSION" 2>/dev/null; then
        fail_test "validate_semver should fail for alpha versions"
    fi
}

test_semver_invalid_format_with_v_prefix() {
    local output
    output=$(validate_semver "v1.2.3" "TEST_VERSION" 2>&1 || true)

    assert_contains "$output" "Invalid TEST_VERSION format: v1.2.3" \
        "Version with 'v' prefix produces error message"

    if validate_semver "v1.2.3" "TEST_VERSION" 2>/dev/null; then
        fail_test "validate_semver should fail for v-prefixed versions"
    fi
}

test_semver_injection_attempt() {
    local output
    output=$(validate_semver "1.2.3; rm -rf /" "TEST_VERSION" 2>&1 || true)

    assert_contains "$output" "Invalid TEST_VERSION format" \
        "Command injection attempt produces error message"

    if validate_semver "1.2.3; rm -rf /" "TEST_VERSION" 2>/dev/null; then
        fail_test "validate_semver should block injection attempts"
    fi
}

test_semver_valid_version_passes() {
    local output
    output=$(validate_semver "1.2.3" "TEST_VERSION" 2>&1)

    assert_not_contains "$output" "ERROR:" \
        "Valid version produces no error"

    # Verify function returns success
    if ! validate_semver "1.2.3" "TEST_VERSION" 2>/dev/null; then
        fail_test "validate_semver should pass for valid version"
    fi
}

# ============================================================================
# Tests for validate_version_flexible - X.Y or X.Y.Z format
# ============================================================================

test_flexible_empty_string() {
    local output
    output=$(validate_version_flexible "" "TEST_VERSION" 2>&1 || true)

    assert_contains "$output" "Empty TEST_VERSION provided" \
        "Empty version produces error message"

    if validate_version_flexible "" "TEST_VERSION" 2>/dev/null; then
        fail_test "validate_version_flexible should fail for empty string"
    fi
}

test_flexible_invalid_format_single_number() {
    local output
    output=$(validate_version_flexible "20" "NODE_VERSION" 2>&1 || true)

    assert_contains "$output" "Invalid NODE_VERSION format: 20" \
        "Single number produces error message"
    assert_contains "$output" "Expected format: X.Y or X.Y.Z" \
        "Error message includes expected format"

    if validate_version_flexible "20" "NODE_VERSION" 2>/dev/null; then
        fail_test "validate_version_flexible should fail for single number"
    fi
}

test_flexible_valid_xy_format() {
    if ! validate_version_flexible "1.23" "GO_VERSION" 2>/dev/null; then
        fail_test "validate_version_flexible should pass for X.Y format"
    fi
}

test_flexible_valid_xyz_format() {
    if ! validate_version_flexible "1.23.5" "GO_VERSION" 2>/dev/null; then
        fail_test "validate_version_flexible should pass for X.Y.Z format"
    fi
}

# ============================================================================
# Tests for validate_node_version - X, X.Y, or X.Y.Z format
# ============================================================================

test_node_version_empty_string() {
    local output
    output=$(validate_node_version "" 2>&1 || true)

    assert_contains "$output" "Empty NODE_VERSION provided" \
        "Empty Node version produces error message"

    if validate_node_version "" 2>/dev/null; then
        fail_test "validate_node_version should fail for empty string"
    fi
}

test_node_version_invalid_characters() {
    local output
    output=$(validate_node_version "20.x" 2>&1 || true)

    assert_contains "$output" "Invalid NODE_VERSION format: 20.x" \
        "Invalid characters produce error message"
    assert_contains "$output" "Only digits and dots allowed" \
        "Error message warns about allowed characters"

    if validate_node_version "20.x" 2>/dev/null; then
        fail_test "validate_node_version should fail for non-numeric versions"
    fi
}

test_node_version_valid_major_only() {
    if ! validate_node_version "22" 2>/dev/null; then
        fail_test "validate_node_version should pass for major version only"
    fi
}

test_node_version_valid_xy_format() {
    if ! validate_node_version "20.18" 2>/dev/null; then
        fail_test "validate_node_version should pass for X.Y format"
    fi
}

test_node_version_valid_xyz_format() {
    if ! validate_node_version "20.18.1" 2>/dev/null; then
        fail_test "validate_node_version should pass for X.Y.Z format"
    fi
}

# ============================================================================
# Tests for validate_python_version
# ============================================================================

test_python_version_empty_string() {
    local output
    output=$(validate_python_version "" 2>&1 || true)

    assert_contains "$output" "Empty PYTHON_VERSION provided" \
        "Empty Python version produces error message"

    if validate_python_version "" 2>/dev/null; then
        fail_test "validate_python_version should fail for empty string"
    fi
}

test_python_version_missing_patch() {
    local output
    output=$(validate_python_version "3.13" 2>&1 || true)

    assert_contains "$output" "Invalid PYTHON_VERSION format: 3.13" \
        "Missing patch version produces error message"

    if validate_python_version "3.13" 2>/dev/null; then
        fail_test "validate_python_version should fail for X.Y format"
    fi
}

test_python_version_valid_format() {
    if ! validate_python_version "3.13.5" 2>/dev/null; then
        fail_test "validate_python_version should pass for X.Y.Z format"
    fi
}

# ============================================================================
# Tests for validate_java_version - flexible format
# ============================================================================

test_java_version_empty_string() {
    local output
    output=$(validate_java_version "" 2>&1 || true)

    assert_contains "$output" "Empty JAVA_VERSION provided" \
        "Empty Java version produces error message"

    if validate_java_version "" 2>/dev/null; then
        fail_test "validate_java_version should fail for empty string"
    fi
}

test_java_version_invalid_format() {
    local output
    output=$(validate_java_version "21-lts" 2>&1 || true)

    assert_contains "$output" "Invalid JAVA_VERSION format: 21-lts" \
        "Invalid format produces error message"

    if validate_java_version "21-lts" 2>/dev/null; then
        fail_test "validate_java_version should fail for non-numeric versions"
    fi
}

test_java_version_valid_major_only() {
    if ! validate_java_version "21" 2>/dev/null; then
        fail_test "validate_java_version should pass for major version only"
    fi
}

test_java_version_valid_xy_format() {
    if ! validate_java_version "11.0" 2>/dev/null; then
        fail_test "validate_java_version should pass for X.Y format"
    fi
}

test_java_version_valid_xyz_format() {
    if ! validate_java_version "11.0.21" 2>/dev/null; then
        fail_test "validate_java_version should pass for X.Y.Z format"
    fi
}

# ============================================================================
# Security Tests - Injection Attempts
# ============================================================================

test_injection_with_backticks() {
    local output
    output=$(validate_semver "\`whoami\`" "TEST_VERSION" 2>&1 || true)

    assert_contains "$output" "Invalid TEST_VERSION format" \
        "Backtick injection attempt produces error message"

    if validate_semver "\`whoami\`" "TEST_VERSION" 2>/dev/null; then
        fail_test "validate_semver should block backtick injection"
    fi
}

test_injection_with_dollar_parens() {
    local output
    output=$(validate_semver "\$(whoami)" "TEST_VERSION" 2>&1 || true)

    assert_contains "$output" "Invalid TEST_VERSION format" \
        "Dollar-paren injection attempt produces error message"

    if validate_semver "\$(whoami)" "TEST_VERSION" 2>/dev/null; then
        fail_test "validate_semver should block dollar-paren injection"
    fi
}

test_injection_with_pipes() {
    local output
    output=$(validate_semver "1.2.3 | cat /etc/passwd" "TEST_VERSION" 2>&1 || true)

    assert_contains "$output" "Invalid TEST_VERSION format" \
        "Pipe injection attempt produces error message"

    if validate_semver "1.2.3 | cat /etc/passwd" "TEST_VERSION" 2>/dev/null; then
        fail_test "validate_semver should block pipe injection"
    fi
}

# ============================================================================
# Run all tests
# ============================================================================

run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"

    setup
    run_test "$test_function" "$test_description"
    teardown
}

# Semver tests
run_test_with_setup test_semver_empty_string "Semver: Empty string error message"
run_test_with_setup test_semver_invalid_format_missing_patch "Semver: Missing patch error message"
run_test_with_setup test_semver_invalid_format_with_alpha "Semver: Alpha suffix error message"
run_test_with_setup test_semver_invalid_format_with_v_prefix "Semver: v-prefix error message"
run_test_with_setup test_semver_injection_attempt "Semver: Injection attempt error message"
run_test_with_setup test_semver_valid_version_passes "Semver: Valid version passes"

# Flexible version tests
run_test_with_setup test_flexible_empty_string "Flexible: Empty string error message"
run_test_with_setup test_flexible_invalid_format_single_number "Flexible: Single number error message"
run_test_with_setup test_flexible_valid_xy_format "Flexible: Valid X.Y format passes"
run_test_with_setup test_flexible_valid_xyz_format "Flexible: Valid X.Y.Z format passes"

# Node version tests
run_test_with_setup test_node_version_empty_string "Node: Empty string error message"
run_test_with_setup test_node_version_invalid_characters "Node: Invalid characters error message"
run_test_with_setup test_node_version_valid_major_only "Node: Valid major-only passes"
run_test_with_setup test_node_version_valid_xy_format "Node: Valid X.Y passes"
run_test_with_setup test_node_version_valid_xyz_format "Node: Valid X.Y.Z passes"

# Python version tests
run_test_with_setup test_python_version_empty_string "Python: Empty string error message"
run_test_with_setup test_python_version_missing_patch "Python: Missing patch error message"
run_test_with_setup test_python_version_valid_format "Python: Valid format passes"

# Java version tests
run_test_with_setup test_java_version_empty_string "Java: Empty string error message"
run_test_with_setup test_java_version_invalid_format "Java: Invalid format error message"
run_test_with_setup test_java_version_valid_major_only "Java: Valid major-only passes"
run_test_with_setup test_java_version_valid_xy_format "Java: Valid X.Y passes"
run_test_with_setup test_java_version_valid_xyz_format "Java: Valid X.Y.Z passes"

# Security tests
run_test_with_setup test_injection_with_backticks "Security: Backtick injection blocked"
run_test_with_setup test_injection_with_dollar_parens "Security: Dollar-paren injection blocked"
run_test_with_setup test_injection_with_pipes "Security: Pipe injection blocked"

# Generate test report
generate_report
