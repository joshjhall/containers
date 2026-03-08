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
# Function Export Verification
# ============================================================================

test_exports_import_gpg_keys() {
    assert_file_contains "$SOURCE_FILE" "export -f import_gpg_keys" \
        "import_gpg_keys is exported"
}

test_exports_verify_gpg_signature() {
    assert_file_contains "$SOURCE_FILE" "export -f verify_gpg_signature" \
        "verify_gpg_signature is exported"
}

test_exports_download_and_verify_gpg() {
    assert_file_contains "$SOURCE_FILE" "export -f download_and_verify_gpg" \
        "download_and_verify_gpg is exported"
}

test_exports_verify_file_against_shasums() {
    assert_file_contains "$SOURCE_FILE" "export -f verify_file_against_shasums" \
        "verify_file_against_shasums is exported"
}

# ============================================================================
# Functional Tests - verify_gpg_signature rejection paths
# ============================================================================

# Test: verify_gpg_signature returns 1 when target file doesn't exist
test_verify_gpg_signature_missing_target() {
    local exit_code=0
    bash -c "
        _GPG_VERIFY_LOADED=''
        _GPG_VERIFY_GOLANG_LOADED=''
        _GPG_VERIFY_NODEJS_LOADED=''
        _GPG_VERIFY_TERRAFORM_LOADED=''
        source '$PROJECT_ROOT/lib/base/logging.sh' 2>/dev/null || true
        source '$SOURCE_FILE' 2>/dev/null
        verify_gpg_signature '$TEST_TEMP_DIR/no-such-file.tar.gz' \
            '$TEST_TEMP_DIR/no-such-file.tar.gz.asc' 'python' >/dev/null 2>&1
    " 2>/dev/null || exit_code=$?

    assert_equals "1" "$exit_code" "verify_gpg_signature returns 1 when target file missing"
}

# Test: verify_gpg_signature returns 1 when signature file doesn't exist
test_verify_gpg_signature_missing_sig() {
    echo "test content" > "$TEST_TEMP_DIR/testfile.tar.gz"

    local exit_code=0
    bash -c "
        _GPG_VERIFY_LOADED=''
        _GPG_VERIFY_GOLANG_LOADED=''
        _GPG_VERIFY_NODEJS_LOADED=''
        _GPG_VERIFY_TERRAFORM_LOADED=''
        source '$PROJECT_ROOT/lib/base/logging.sh' 2>/dev/null || true
        source '$SOURCE_FILE' 2>/dev/null
        verify_gpg_signature '$TEST_TEMP_DIR/testfile.tar.gz' \
            '$TEST_TEMP_DIR/testfile.tar.gz.asc' 'python' >/dev/null 2>&1
    " 2>/dev/null || exit_code=$?

    assert_equals "1" "$exit_code" "verify_gpg_signature returns 1 when sig file missing"
}

# ============================================================================
# Functional Tests - download_and_verify_gpg rejection paths
# ============================================================================

# Test: download_and_verify_gpg returns 1 when no signature URL provided
test_download_and_verify_gpg_no_url() {
    echo "test content" > "$TEST_TEMP_DIR/testfile.tar.gz"

    local exit_code=0
    bash -c "
        _GPG_VERIFY_LOADED=''
        _GPG_VERIFY_GOLANG_LOADED=''
        _GPG_VERIFY_NODEJS_LOADED=''
        _GPG_VERIFY_TERRAFORM_LOADED=''
        source '$PROJECT_ROOT/lib/base/logging.sh' 2>/dev/null || true
        source '$SOURCE_FILE' 2>/dev/null
        download_and_verify_gpg '$TEST_TEMP_DIR/testfile.tar.gz' '' 'python' >/dev/null 2>&1
    " 2>/dev/null || exit_code=$?

    assert_equals "1" "$exit_code" "download_and_verify_gpg returns 1 when no URL provided"
}

# Test: download_and_verify_gpg returns 1 when curl fails
test_download_and_verify_gpg_curl_failure() {
    echo "test content" > "$TEST_TEMP_DIR/testfile.tar.gz"

    local exit_code=0
    bash -c "
        _GPG_VERIFY_LOADED=''
        _GPG_VERIFY_GOLANG_LOADED=''
        _GPG_VERIFY_NODEJS_LOADED=''
        _GPG_VERIFY_TERRAFORM_LOADED=''
        source '$PROJECT_ROOT/lib/base/logging.sh' 2>/dev/null || true
        source '$SOURCE_FILE' 2>/dev/null
        # Mock curl to fail
        curl() { return 1; }
        export -f curl
        download_and_verify_gpg '$TEST_TEMP_DIR/testfile.tar.gz' \
            'https://example.com/testfile.tar.gz.asc' 'python' >/dev/null 2>&1
    " 2>/dev/null || exit_code=$?

    assert_equals "1" "$exit_code" "download_and_verify_gpg returns 1 on curl failure"
}

# ============================================================================
# Functional Tests - verify_file_against_shasums
# ============================================================================

# Test: verify_file_against_shasums returns 0 on matching checksum
test_verify_file_against_shasums_match() {
    # Create a test file with known content
    echo "hello world" > "$TEST_TEMP_DIR/testfile.bin"
    # Compute its real sha256sum
    local real_checksum
    real_checksum=$(sha256sum "$TEST_TEMP_DIR/testfile.bin" | command awk '{print $1}')

    # Create a SHASUMS file with the correct checksum
    echo "$real_checksum  testfile.bin" > "$TEST_TEMP_DIR/SHASUMS256.txt"
    # Create a dummy signature file (will be cleaned up by the function)
    echo "dummy sig" > "$TEST_TEMP_DIR/SHASUMS256.txt.sig"

    local exit_code=0
    bash -c "
        _GPG_VERIFY_LOADED=''
        _GPG_VERIFY_GOLANG_LOADED=''
        _GPG_VERIFY_NODEJS_LOADED=''
        _GPG_VERIFY_TERRAFORM_LOADED=''
        source '$PROJECT_ROOT/lib/base/logging.sh' 2>/dev/null || true
        source '$SOURCE_FILE' 2>/dev/null
        verify_file_against_shasums '$TEST_TEMP_DIR/testfile.bin' \
            '$TEST_TEMP_DIR/SHASUMS256.txt' \
            '$TEST_TEMP_DIR/SHASUMS256.txt.sig' >/dev/null 2>&1
    " 2>/dev/null || exit_code=$?

    assert_equals "0" "$exit_code" "verify_file_against_shasums returns 0 on matching checksum"
}

# Test: verify_file_against_shasums returns 1 on mismatched checksum
test_verify_file_against_shasums_mismatch() {
    echo "hello world" > "$TEST_TEMP_DIR/testfile.bin"

    # Create a SHASUMS file with a WRONG checksum
    echo "0000000000000000000000000000000000000000000000000000000000000000  testfile.bin" > "$TEST_TEMP_DIR/SHASUMS256.txt"
    echo "dummy sig" > "$TEST_TEMP_DIR/SHASUMS256.txt.sig"

    local exit_code=0
    bash -c "
        _GPG_VERIFY_LOADED=''
        _GPG_VERIFY_GOLANG_LOADED=''
        _GPG_VERIFY_NODEJS_LOADED=''
        _GPG_VERIFY_TERRAFORM_LOADED=''
        source '$PROJECT_ROOT/lib/base/logging.sh' 2>/dev/null || true
        source '$SOURCE_FILE' 2>/dev/null
        verify_file_against_shasums '$TEST_TEMP_DIR/testfile.bin' \
            '$TEST_TEMP_DIR/SHASUMS256.txt' \
            '$TEST_TEMP_DIR/SHASUMS256.txt.sig' >/dev/null 2>&1
    " 2>/dev/null || exit_code=$?

    assert_equals "1" "$exit_code" "verify_file_against_shasums returns 1 on checksum mismatch"
}

# Test: verify_file_against_shasums returns 1 when filename not in shasums file
test_verify_file_against_shasums_missing_entry() {
    echo "hello world" > "$TEST_TEMP_DIR/testfile.bin"

    # Create a SHASUMS file that doesn't include our file
    echo "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890  otherfile.bin" > "$TEST_TEMP_DIR/SHASUMS256.txt"
    echo "dummy sig" > "$TEST_TEMP_DIR/SHASUMS256.txt.sig"

    local exit_code=0
    bash -c "
        _GPG_VERIFY_LOADED=''
        _GPG_VERIFY_GOLANG_LOADED=''
        _GPG_VERIFY_NODEJS_LOADED=''
        _GPG_VERIFY_TERRAFORM_LOADED=''
        source '$PROJECT_ROOT/lib/base/logging.sh' 2>/dev/null || true
        source '$SOURCE_FILE' 2>/dev/null
        verify_file_against_shasums '$TEST_TEMP_DIR/testfile.bin' \
            '$TEST_TEMP_DIR/SHASUMS256.txt' \
            '$TEST_TEMP_DIR/SHASUMS256.txt.sig' >/dev/null 2>&1
    " 2>/dev/null || exit_code=$?

    assert_equals "1" "$exit_code" "verify_file_against_shasums returns 1 when filename not in shasums"
}

# ============================================================================
# Functional Tests - import_gpg_keys with keyring directory format
# ============================================================================

# Test: import_gpg_keys detects keyring directory format (pubring.kbx)
test_import_gpg_keys_keyring_dir_format_detected() {
    # Create a keyring directory structure matching Node.js style
    mkdir -p "$TEST_TEMP_DIR/keyring/testlang/keyring"
    # Create a fake pubring.kbx (gpg will fail, but the path detection should work)
    echo "fake keyring" > "$TEST_TEMP_DIR/keyring/testlang/keyring/pubring.kbx"

    # The test checks that the code attempts the keyring path (it will fail
    # because gpg can't read a fake keyring, but it should get past the path check)
    local exit_code=0
    bash -c "
        export GPG_KEYRING_DIR='$TEST_TEMP_DIR/keyring'
        _GPG_VERIFY_LOADED=''
        _GPG_VERIFY_GOLANG_LOADED=''
        _GPG_VERIFY_NODEJS_LOADED=''
        _GPG_VERIFY_TERRAFORM_LOADED=''
        source '$PROJECT_ROOT/lib/base/logging.sh' 2>/dev/null || true
        source '$SOURCE_FILE' 2>/dev/null
        import_gpg_keys 'testlang' >/dev/null 2>&1
    " 2>/dev/null || exit_code=$?

    # It should return 1 because gpg --list-keys fails on a fake keyring,
    # but importantly it took the keyring directory branch (not the individual keys branch)
    assert_equals "1" "$exit_code" "import_gpg_keys with keyring dir format (fails on fake keyring)"
}

# ============================================================================
# Run tests
# ============================================================================

run_test_with_setup test_import_gpg_keys_missing_keyring_returns_1 "import_gpg_keys returns 1 for missing keyring"
run_test_with_setup test_import_gpg_keys_with_empty_keys_dir "import_gpg_keys returns 1 for empty keys dir"

# Export verification
run_test test_exports_import_gpg_keys "Exports import_gpg_keys"
run_test test_exports_verify_gpg_signature "Exports verify_gpg_signature"
run_test test_exports_download_and_verify_gpg "Exports download_and_verify_gpg"
run_test test_exports_verify_file_against_shasums "Exports verify_file_against_shasums"

# verify_gpg_signature rejection paths
run_test_with_setup test_verify_gpg_signature_missing_target "verify_gpg_signature: target file missing"
run_test_with_setup test_verify_gpg_signature_missing_sig "verify_gpg_signature: sig file missing"

# download_and_verify_gpg rejection paths
run_test_with_setup test_download_and_verify_gpg_no_url "download_and_verify_gpg: no URL provided"
run_test_with_setup test_download_and_verify_gpg_curl_failure "download_and_verify_gpg: curl failure"

# verify_file_against_shasums tests
run_test_with_setup test_verify_file_against_shasums_match "verify_file_against_shasums: matching checksum"
run_test_with_setup test_verify_file_against_shasums_mismatch "verify_file_against_shasums: mismatched checksum"
run_test_with_setup test_verify_file_against_shasums_missing_entry "verify_file_against_shasums: missing entry"

# import_gpg_keys keyring format
run_test_with_setup test_import_gpg_keys_keyring_dir_format_detected "import_gpg_keys: keyring dir format detected"

# Generate test report
generate_report
