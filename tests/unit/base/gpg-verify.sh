#!/bin/bash
# Unit tests for lib/base/gpg-verify.sh
# Tests GPG key import and signature verification with GPG_KEYRING_DIR override

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "GPG Verification Tests"

# Path to script under test
SOURCE_FILE="$PROJECT_ROOT/lib/base/gpg-verify.sh"

# Setup function
setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$RESULTS_DIR/test-gpg-verify-$unique_id"
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
# Functional Tests - import_gpg_keys with GPG_KEYRING_DIR override
# ============================================================================

# Test: import_gpg_keys returns 1 when keyring directory does not exist
test_import_gpg_keys_missing_keyring_returns_1() {
    local exit_code=0
    bash -c "
        export GPG_KEYRING_DIR='$TEST_TEMP_DIR/empty-keyring'
        _GPG_VERIFY_LOADED=''
        source '$PROJECT_ROOT/lib/base/logging.sh' 2>/dev/null || true
        source '$SOURCE_FILE' 2>/dev/null
        import_gpg_keys 'nonexistent_lang' >/dev/null 2>&1
    " 2>/dev/null || exit_code=$?

    assert_equals "1" "$exit_code" "import_gpg_keys returns 1 for missing keyring directory"
}

# Test: import_gpg_keys returns 1 when keys directory is empty (no key files)
test_import_gpg_keys_with_empty_keys_dir() {
    # Create the language keyring directory with an empty keys/ subdirectory
    mkdir -p "$TEST_TEMP_DIR/keyring/testlang/keys"

    local exit_code=0
    bash -c "
        export GPG_KEYRING_DIR='$TEST_TEMP_DIR/keyring'
        _GPG_VERIFY_LOADED=''
        source '$PROJECT_ROOT/lib/base/logging.sh' 2>/dev/null || true
        source '$SOURCE_FILE' 2>/dev/null
        import_gpg_keys 'testlang' >/dev/null 2>&1
    " 2>/dev/null || exit_code=$?

    assert_equals "1" "$exit_code" "import_gpg_keys returns 1 when keys directory is empty"
}

# ============================================================================
# Run tests
# ============================================================================

run_test_with_setup test_import_gpg_keys_missing_keyring_returns_1 "import_gpg_keys returns 1 for missing keyring"
run_test_with_setup test_import_gpg_keys_with_empty_keys_dir "import_gpg_keys returns 1 for empty keys dir"

# Generate test report
generate_report
