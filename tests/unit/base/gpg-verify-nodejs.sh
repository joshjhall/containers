#!/bin/bash
# Unit tests for lib/base/gpg-verify-nodejs.sh
# Tests Node.js-specific GPG verification

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "GPG Verify Node.js Tests"

# Path to script under test
SOURCE_FILE="$PROJECT_ROOT/lib/base/gpg-verify-nodejs.sh"
PARENT_FILE="$PROJECT_ROOT/lib/base/gpg-verify.sh"

# Setup function
setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$RESULTS_DIR/test-gpg-verify-nodejs-$unique_id"
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
test_exports_download_and_verify_nodejs_gpg() {
    assert_file_contains "$SOURCE_FILE" "protected_export.*download_and_verify_nodejs_gpg" \
        "download_and_verify_nodejs_gpg is exported"
}

# Test: function definition exists
test_defines_download_and_verify_nodejs_gpg() {
    assert_file_contains "$SOURCE_FILE" "download_and_verify_nodejs_gpg()" \
        "Script defines download_and_verify_nodejs_gpg function"
}

# Test: sources gpg-verify.sh (via parent module)
test_sourced_by_gpg_verify() {
    assert_file_contains "$PARENT_FILE" "gpg-verify-nodejs.sh" \
        "gpg-verify.sh sources gpg-verify-nodejs.sh"
}

# Test: uses correct keyring name "nodejs"
test_uses_nodejs_keyring() {
    assert_file_contains "$SOURCE_FILE" '"nodejs"' \
        "Uses 'nodejs' keyring name for GPG verification"
}

# Test: URL pattern for SHASUMS256.txt
test_url_pattern_shasums() {
    assert_file_contains "$SOURCE_FILE" 'https://nodejs.org/dist/v${version}/SHASUMS256.txt' \
        "URL pattern: nodejs.org/dist/v{version}/SHASUMS256.txt"
}

# Test: tries .sig first then .asc for signature download
test_tries_sig_then_asc() {
    assert_file_contains "$SOURCE_FILE" "for ext in sig asc" \
        "Tries .sig first then .asc for signature download"
}

# ============================================================================
# Functional Tests
# ============================================================================

# Test: returns 1 when SHASUMS download fails
test_shasums_download_failure_returns_1() {
    local exit_code=0
    # Create a fake node binary
    mkdir -p "$TEST_TEMP_DIR/dl"
    echo "fake node binary" >"$TEST_TEMP_DIR/dl/node-v20.18.0-linux-x64.tar.xz"

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
        download_and_verify_nodejs_gpg '$TEST_TEMP_DIR/dl/node-v20.18.0-linux-x64.tar.xz' '20.18.0' >/dev/null 2>&1
    " 2>/dev/null || exit_code=$?

    assert_equals "1" "$exit_code" "download_and_verify_nodejs_gpg returns 1 on SHASUMS download failure"
}

# ============================================================================
# Run all tests
# ============================================================================

# Static analysis
run_test test_exports_download_and_verify_nodejs_gpg "Exports download_and_verify_nodejs_gpg"
run_test test_defines_download_and_verify_nodejs_gpg "Defines download_and_verify_nodejs_gpg function"
run_test test_sourced_by_gpg_verify "gpg-verify.sh sources nodejs sub-module"
run_test test_uses_nodejs_keyring "Uses 'nodejs' keyring name"
run_test test_url_pattern_shasums "URL pattern: SHASUMS256.txt"
run_test test_tries_sig_then_asc "Tries .sig first then .asc"

# Functional tests
run_test_with_setup test_shasums_download_failure_returns_1 "SHASUMS download failure returns 1"

# Generate test report
generate_report
