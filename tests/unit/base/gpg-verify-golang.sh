#!/bin/bash
# Unit tests for lib/base/gpg-verify-golang.sh
# Tests Go-specific GPG verification

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "GPG Verify Golang Tests"

# Path to script under test
SOURCE_FILE="$PROJECT_ROOT/lib/base/gpg-verify-golang.sh"
PARENT_FILE="$PROJECT_ROOT/lib/base/gpg-verify.sh"

# Setup function
setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$RESULTS_DIR/test-gpg-verify-golang-$unique_id"
    mkdir -p "$TEST_TEMP_DIR"
}

# Teardown function
teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
}

run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"
    setup
    run_test "$test_function" "$test_description"
    teardown
}

# ============================================================================
# Static Analysis Tests
# ============================================================================

# Test: function exists and is exported
test_exports_download_and_verify_golang_gpg() {
    assert_file_contains "$SOURCE_FILE" "protected_export.*download_and_verify_golang_gpg" \
        "download_and_verify_golang_gpg is exported"
}

# Test: function definition exists
test_defines_download_and_verify_golang_gpg() {
    assert_file_contains "$SOURCE_FILE" "download_and_verify_golang_gpg()" \
        "Script defines download_and_verify_golang_gpg function"
}

# Test: sources gpg-verify.sh (via parent module)
test_sourced_by_gpg_verify() {
    assert_file_contains "$PARENT_FILE" "gpg-verify-golang.sh" \
        "gpg-verify.sh sources gpg-verify-golang.sh"
}

# Test: uses correct keyring name "golang"
test_uses_golang_keyring() {
    assert_file_contains "$SOURCE_FILE" '"golang"' \
        "Uses 'golang' keyring name for GPG verification"
}

# Test: constructs correct URL pattern (https://go.dev/dl/{filename}.asc)
test_url_pattern() {
    assert_file_contains "$SOURCE_FILE" 'https://go.dev/dl/${filename}.asc' \
        "Constructs go.dev URL with .asc extension"
}

# ============================================================================
# Functional Tests
# ============================================================================

# Test: returns 1 when curl fails to download .asc signature
test_curl_failure_returns_1() {
    local exit_code=0
    # Create a fake file to verify
    echo "fake go binary" >"$TEST_TEMP_DIR/go1.23.4.linux-amd64.tar.gz"

    bash -c "
        _GPG_VERIFY_LOADED=''
        _GPG_VERIFY_GOLANG_LOADED=''
        _GPG_VERIFY_NODEJS_LOADED=''
        _GPG_VERIFY_TERRAFORM_LOADED=''
        source '$PROJECT_ROOT/lib/base/logging.sh' 2>/dev/null || true
        source '$PARENT_FILE' 2>/dev/null
        # Mock curl to always fail
        curl() { return 1; }
        export -f curl
        download_and_verify_golang_gpg '$TEST_TEMP_DIR/go1.23.4.linux-amd64.tar.gz' '1.23.4' >/dev/null 2>&1
    " 2>/dev/null || exit_code=$?

    assert_equals "1" "$exit_code" "download_and_verify_golang_gpg returns 1 on curl failure"
}

# ============================================================================
# Run all tests
# ============================================================================

# Static analysis
run_test test_exports_download_and_verify_golang_gpg "Exports download_and_verify_golang_gpg"
run_test test_defines_download_and_verify_golang_gpg "Defines download_and_verify_golang_gpg function"
run_test test_sourced_by_gpg_verify "gpg-verify.sh sources golang sub-module"
run_test test_uses_golang_keyring "Uses 'golang' keyring name"
run_test test_url_pattern "URL pattern: go.dev/dl/{filename}.asc"

# Functional tests
run_test_with_setup test_curl_failure_returns_1 "curl failure returns 1"

# Generate test report
generate_report
