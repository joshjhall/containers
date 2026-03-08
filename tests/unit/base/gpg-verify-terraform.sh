#!/bin/bash
# Unit tests for lib/base/gpg-verify-terraform.sh
# Tests Terraform-specific GPG verification

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "GPG Verify Terraform Tests"

# Path to script under test
SOURCE_FILE="$PROJECT_ROOT/lib/base/gpg-verify-terraform.sh"
PARENT_FILE="$PROJECT_ROOT/lib/base/gpg-verify.sh"

# Setup function
setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$RESULTS_DIR/test-gpg-verify-terraform-$unique_id"
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
test_exports_download_and_verify_terraform_gpg() {
    assert_file_contains "$SOURCE_FILE" "export -f download_and_verify_terraform_gpg" \
        "download_and_verify_terraform_gpg is exported"
}

# Test: function definition exists
test_defines_download_and_verify_terraform_gpg() {
    assert_file_contains "$SOURCE_FILE" "download_and_verify_terraform_gpg()" \
        "Script defines download_and_verify_terraform_gpg function"
}

# Test: sources gpg-verify.sh (via parent module)
test_sourced_by_gpg_verify() {
    assert_file_contains "$PARENT_FILE" "gpg-verify-terraform.sh" \
        "gpg-verify.sh sources gpg-verify-terraform.sh"
}

# Test: uses correct keyring name "hashicorp"
test_uses_hashicorp_keyring() {
    assert_file_contains "$SOURCE_FILE" '"hashicorp"' \
        "Uses 'hashicorp' keyring name for GPG verification"
}

# Test: URL pattern for SHA256SUMS
test_url_pattern_sha256sums() {
    assert_file_contains "$SOURCE_FILE" \
        'https://releases.hashicorp.com/terraform/${version}/terraform_${version}_SHA256SUMS' \
        "URL pattern: releases.hashicorp.com/terraform/{version}/terraform_{version}_SHA256SUMS"
}

# ============================================================================
# Functional Tests
# ============================================================================

# Test: returns 1 when SHASUMS download fails
test_shasums_download_failure_returns_1() {
    local exit_code=0
    # Create a fake terraform binary
    mkdir -p "$TEST_TEMP_DIR/dl"
    echo "fake terraform binary" > "$TEST_TEMP_DIR/dl/terraform_1.10.0_linux_amd64.zip"

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
        download_and_verify_terraform_gpg '$TEST_TEMP_DIR/dl/terraform_1.10.0_linux_amd64.zip' '1.10.0' >/dev/null 2>&1
    " 2>/dev/null || exit_code=$?

    assert_equals "1" "$exit_code" "download_and_verify_terraform_gpg returns 1 on SHA256SUMS download failure"
}

# ============================================================================
# Run all tests
# ============================================================================

# Static analysis
run_test test_exports_download_and_verify_terraform_gpg "Exports download_and_verify_terraform_gpg"
run_test test_defines_download_and_verify_terraform_gpg "Defines download_and_verify_terraform_gpg function"
run_test test_sourced_by_gpg_verify "gpg-verify.sh sources terraform sub-module"
run_test test_uses_hashicorp_keyring "Uses 'hashicorp' keyring name"
run_test test_url_pattern_sha256sums "URL pattern: SHA256SUMS"

# Functional tests
run_test_with_setup test_shasums_download_failure_returns_1 "SHA256SUMS download failure returns 1"

# Generate test report
generate_report
