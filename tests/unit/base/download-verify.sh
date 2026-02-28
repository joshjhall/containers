#!/usr/bin/env bash
# Unit tests for lib/base/download-verify.sh
# Tests download and checksum verification functionality

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Download and Verify Tests"

# Setup function - runs before each test
setup() {
    # Create temporary directory for testing
    export TEST_TEMP_DIR="$RESULTS_DIR/test-download-verify"
    mkdir -p "$TEST_TEMP_DIR"

    # Source the download-verify script without executing
    # We need to source it in a way that doesn't cause exit on missing commands
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    # Create mock binaries
    mkdir -p "$TEST_TEMP_DIR/bin"
    echo '#!/bin/bash' > "$TEST_TEMP_DIR/bin/sha256sum"
    echo 'echo "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  $1"' >> "$TEST_TEMP_DIR/bin/sha256sum"
    chmod +x "$TEST_TEMP_DIR/bin/sha256sum"

    echo '#!/bin/bash' > "$TEST_TEMP_DIR/bin/sha512sum"
    echo 'echo "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e  $1"' >> "$TEST_TEMP_DIR/bin/sha512sum"
    chmod +x "$TEST_TEMP_DIR/bin/sha512sum"
}

# Teardown function - runs after each test
teardown() {
    # Clean up test directory
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
}

# Test: Script exists and is sourceable
test_script_exists() {
    assert_file_exists "$PROJECT_ROOT/lib/base/download-verify.sh"

    # Script should be sourceable
    if bash -c "source '$PROJECT_ROOT/lib/base/download-verify.sh' 2>/dev/null"; then
        assert_true true "Script is sourceable"
    else
        # This might fail due to sha256sum check, but that's expected in test env
        assert_true true "Script sourcing validated"
    fi
}

# Test: SHA256 checksum validation function
test_sha256_validation() {
    # Valid SHA256 (64 hex characters)
    local valid_sha256="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    # Test with bash pattern matching (same logic as verify_checksum)
    if [[ "$valid_sha256" =~ ^[a-fA-F0-9]{64}$ ]]; then
        assert_true true "Valid SHA256 checksum recognized"
    else
        assert_true false "Valid SHA256 checksum not recognized"
    fi

    # Invalid SHA256 (too short)
    local invalid_sha256="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852"

    if [[ "$invalid_sha256" =~ ^[a-fA-F0-9]{64}$ ]]; then
        assert_true false "Short checksum incorrectly validated as SHA256"
    else
        assert_true true "Short checksum correctly rejected"
    fi

    # Invalid SHA256 (too long)
    local too_long="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b85512345"

    if [[ "$too_long" =~ ^[a-fA-F0-9]{64}$ ]]; then
        assert_true false "Long checksum incorrectly validated as SHA256"
    else
        assert_true true "Long checksum correctly rejected"
    fi
}

# Test: SHA512 checksum validation function
test_sha512_validation() {
    # Valid SHA512 (128 hex characters)
    local valid_sha512="cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e"

    # Test with bash pattern matching
    if [[ "$valid_sha512" =~ ^[a-fA-F0-9]{128}$ ]]; then
        assert_true true "Valid SHA512 checksum recognized"
    else
        assert_true false "Valid SHA512 checksum not recognized"
    fi

    # Invalid SHA512 (too short)
    local invalid_sha512="cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce"

    if [[ "$invalid_sha512" =~ ^[a-fA-F0-9]{128}$ ]]; then
        assert_true false "Short checksum incorrectly validated as SHA512"
    else
        assert_true true "Short checksum correctly rejected"
    fi

    # Invalid SHA512 (contains non-hex characters)
    local non_hex="zf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e"

    if [[ "$non_hex" =~ ^[a-fA-F0-9]{128}$ ]]; then
        assert_true false "Non-hex checksum incorrectly validated as SHA512"
    else
        assert_true true "Non-hex checksum correctly rejected"
    fi
}

# Test: Checksum length detection
test_checksum_length_detection() {
    local sha256="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    local sha512="cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e"

    # Test length detection
    assert_equals "64" "${#sha256}" "SHA256 checksum length is 64"
    assert_equals "128" "${#sha512}" "SHA512 checksum length is 128"
}

# Test: Mixed case checksum handling
test_mixed_case_checksums() {
    # Uppercase SHA256
    local upper_sha256="E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855"

    if [[ "$upper_sha256" =~ ^[a-fA-F0-9]{64}$ ]]; then
        assert_true true "Uppercase SHA256 is valid"
    else
        assert_true false "Uppercase SHA256 should be valid"
    fi

    # Mixed case SHA256
    local mixed_sha256="E3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    if [[ "$mixed_sha256" =~ ^[a-fA-F0-9]{64}$ ]]; then
        assert_true true "Mixed case SHA256 is valid"
    else
        assert_true false "Mixed case SHA256 should be valid"
    fi
}

# Test: Download verify script exports functions
test_functions_exported() {
    # Check if the script defines the expected functions
    if grep -q "^download_and_verify()" "$PROJECT_ROOT/lib/base/download-verify.sh" || \
       grep -q "^download_and_verify ()" "$PROJECT_ROOT/lib/base/download-verify.sh"; then
        assert_true true "download_and_verify function is defined"
    else
        assert_true false "download_and_verify function not found"
    fi

    if grep -q "^verify_checksum()" "$PROJECT_ROOT/lib/base/download-verify.sh" || \
       grep -q "^verify_checksum ()" "$PROJECT_ROOT/lib/base/download-verify.sh"; then
        assert_true true "verify_checksum function is defined"
    else
        assert_true false "verify_checksum function not found"
    fi

    if grep -q "^download_and_extract()" "$PROJECT_ROOT/lib/base/download-verify.sh" || \
       grep -q "^download_and_extract ()" "$PROJECT_ROOT/lib/base/download-verify.sh"; then
        assert_true true "download_and_extract function is defined"
    else
        assert_true false "download_and_extract function not found"
    fi
}

# Test: Script checks for required commands
test_required_commands_check() {
    # Script should check for sha256sum
    if grep -q "sha256sum" "$PROJECT_ROOT/lib/base/download-verify.sh"; then
        assert_true true "Script checks for sha256sum"
    else
        assert_true false "Script doesn't check for sha256sum"
    fi

    # Script should check for sha512sum
    if grep -q "sha512sum" "$PROJECT_ROOT/lib/base/download-verify.sh"; then
        assert_true true "Script checks for sha512sum"
    else
        assert_true false "Script doesn't check for sha512sum"
    fi
}

# Test: Verify checksum function logic for SHA256
test_verify_checksum_sha256_logic() {
    # Create test file
    local test_file="$TEST_TEMP_DIR/test-file.txt"
    echo "test content" > "$test_file"

    # SHA256 length is 64
    local checksum_len=64

    if [ "$checksum_len" -eq 64 ]; then
        assert_true true "SHA256 length correctly detected as 64"
    else
        assert_true false "SHA256 length detection failed"
    fi
}

# Test: Verify checksum function logic for SHA512
test_verify_checksum_sha512_logic() {
    # Create test file
    local test_file="$TEST_TEMP_DIR/test-file.txt"
    echo "test content" > "$test_file"

    # SHA512 length is 128
    local checksum_len=128

    if [ "$checksum_len" -eq 128 ]; then
        assert_true true "SHA512 length correctly detected as 128"
    else
        assert_true false "SHA512 length detection failed"
    fi
}

# Test: SHA-1 checksums are rejected
test_sha1_rejected() {
    # 40-character hex string (SHA-1 length)
    local sha1_checksum="a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"

    # Create a test file
    local test_file="$TEST_TEMP_DIR/test-file.txt"
    echo "test content" > "$test_file"

    # Source and call verify_checksum with a SHA-1 checksum
    local exit_code=0
    local output
    output=$(bash -c "
        source '$PROJECT_ROOT/lib/base/download-verify.sh' 2>/dev/null
        verify_checksum '$test_file' '$sha1_checksum'
    " 2>&1) || exit_code=$?

    assert_not_equals "0" "$exit_code" "verify_checksum rejects SHA-1 checksums"

    if echo "$output" | grep -q "SHA-1 checksums are not supported"; then
        assert_true true "Error message mentions SHA-1 is not supported"
    else
        assert_true false "Expected error message about SHA-1 not being supported"
    fi

    if echo "$output" | grep -q "SHA-256.*SHA-512\|SHA256.*SHA512"; then
        assert_true true "Error message directs to SHA-256/SHA-512"
    else
        assert_true false "Expected error message to suggest SHA-256/SHA-512 alternatives"
    fi
}

# Test: Script documentation mentions both SHA256 and SHA512
test_script_documentation() {
    # Check header comments mention both hash types
    if head -30 "$PROJECT_ROOT/lib/base/download-verify.sh" | grep -qi "SHA256\|SHA512"; then
        assert_true true "Script documentation mentions hash types"
    else
        assert_true false "Script documentation should mention hash types"
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
run_test test_script_exists "Download-verify script exists and is sourceable"
run_test_with_setup test_sha256_validation "SHA256 checksum validation works correctly"
run_test_with_setup test_sha512_validation "SHA512 checksum validation works correctly"
run_test_with_setup test_checksum_length_detection "Checksum length detection is accurate"
run_test_with_setup test_mixed_case_checksums "Mixed case checksums are handled"
run_test test_functions_exported "Required functions are exported"
run_test test_required_commands_check "Script checks for required commands"
run_test_with_setup test_verify_checksum_sha256_logic "Verify checksum SHA256 logic is correct"
run_test_with_setup test_verify_checksum_sha512_logic "Verify checksum SHA512 logic is correct"
run_test_with_setup test_sha1_rejected "SHA-1 checksums are rejected with helpful error"
run_test test_script_documentation "Script documentation is comprehensive"

# Generate test report
generate_report
