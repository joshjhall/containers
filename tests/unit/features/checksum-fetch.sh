#!/usr/bin/env bash
# Unit tests for lib/features/lib/checksum-fetch.sh
# Tests checksum fetching utilities for download verification

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Checksum Fetch Tests"

# Source file under test
SOURCE_FILE="$PROJECT_ROOT/lib/features/lib/checksum-fetch.sh"

# Setup function - runs before each test
setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$RESULTS_DIR/test-checksum-fetch-$unique_id"
    mkdir -p "$TEST_TEMP_DIR"
    mkdir -p "$TEST_TEMP_DIR/bin"
}

# Teardown function - runs after each test
teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
    unset TEST_TEMP_DIR 2>/dev/null || true
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
_run_fetch_subshell() {
    # Runs the provided commands in a subshell, suppressing all log output
    # Usage: result=$(_run_fetch_subshell "commands...")
    bash -c "
        # Provide fallback for retry-utils dependency
        retry_github_api() { \"\$@\"; }
        export -f retry_github_api
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

test_defines_fetch_go_checksum() {
    assert_file_contains "$SOURCE_FILE" "fetch_go_checksum()" \
        "Script defines fetch_go_checksum function"
}

test_defines_fetch_github_checksums_txt() {
    assert_file_contains "$SOURCE_FILE" "fetch_github_checksums_txt()" \
        "Script defines fetch_github_checksums_txt function"
}

test_defines_fetch_github_sha256_file() {
    assert_file_contains "$SOURCE_FILE" "fetch_github_sha256_file()" \
        "Script defines fetch_github_sha256_file function"
}

test_defines_fetch_github_sha512_file() {
    assert_file_contains "$SOURCE_FILE" "fetch_github_sha512_file()" \
        "Script defines fetch_github_sha512_file function"
}

test_defines_fetch_ruby_checksum() {
    assert_file_contains "$SOURCE_FILE" "fetch_ruby_checksum()" \
        "Script defines fetch_ruby_checksum function"
}

test_defines_fetch_maven_sha1() {
    assert_file_contains "$SOURCE_FILE" "fetch_maven_sha1()" \
        "Script defines fetch_maven_sha1 function"
}

test_defines_validate_checksum_format() {
    assert_file_contains "$SOURCE_FILE" "validate_checksum_format()" \
        "Script defines validate_checksum_format function"
}

test_defines_is_partial_version() {
    assert_file_contains "$SOURCE_FILE" "_is_partial_version()" \
        "Script defines _is_partial_version function"
}

test_defines_calculate_checksum_sha256() {
    assert_file_contains "$SOURCE_FILE" "calculate_checksum_sha256()" \
        "Script defines calculate_checksum_sha256 function"
}

# ============================================================================
# Static Analysis - URL patterns
# ============================================================================

test_go_url_pattern() {
    assert_file_contains "$SOURCE_FILE" "https://go.dev/dl/" \
        "Go checksum fetching uses go.dev URL"
}

test_ruby_url_pattern() {
    assert_file_contains "$SOURCE_FILE" "https://www.ruby-lang.org" \
        "Ruby checksum fetching uses ruby-lang.org URL"
}

test_curl_timeout_configured() {
    assert_file_contains "$SOURCE_FILE" "connect-timeout" \
        "Curl calls include connection timeout"
}

test_curl_max_time_configured() {
    assert_file_contains "$SOURCE_FILE" "max-time" \
        "Curl calls include max-time timeout"
}

# ============================================================================
# Functional Tests - validate_checksum_format()
# ============================================================================

test_validate_checksum_format_sha256_valid() {
    local valid_sha256="a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"

    local exit_code=0
    _run_fetch_subshell "validate_checksum_format '$valid_sha256' 'sha256'" || exit_code=$?

    assert_equals "0" "$exit_code" "validate_checksum_format accepts valid SHA256 (64 hex chars)"
}

test_validate_checksum_format_sha256_invalid_short() {
    local short_hash="a1b2c3d4e5f6"

    local exit_code=0
    _run_fetch_subshell "validate_checksum_format '$short_hash' 'sha256'" || exit_code=$?

    assert_equals "1" "$exit_code" "validate_checksum_format rejects short SHA256"
}

test_validate_checksum_format_sha256_invalid_chars() {
    # 64 chars but with invalid hex characters (g, h, z)
    local bad_hash="g1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"

    local exit_code=0
    _run_fetch_subshell "validate_checksum_format '$bad_hash' 'sha256'" || exit_code=$?

    assert_equals "1" "$exit_code" "validate_checksum_format rejects non-hex characters in SHA256"
}

test_validate_checksum_format_sha512_valid() {
    local valid_sha512
    valid_sha512="a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
    valid_sha512="${valid_sha512}a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"

    local exit_code=0
    _run_fetch_subshell "validate_checksum_format '$valid_sha512' 'sha512'" || exit_code=$?

    assert_equals "0" "$exit_code" "validate_checksum_format accepts valid SHA512 (128 hex chars)"
}

test_validate_checksum_format_sha512_invalid_short() {
    local short_sha512="a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"

    local exit_code=0
    _run_fetch_subshell "validate_checksum_format '$short_sha512' 'sha512'" || exit_code=$?

    assert_equals "1" "$exit_code" "validate_checksum_format rejects 64-char string as SHA512"
}

test_validate_checksum_format_sha1_valid() {
    local valid_sha1="a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"

    local exit_code=0
    _run_fetch_subshell "validate_checksum_format '$valid_sha1' 'sha1'" || exit_code=$?

    assert_equals "0" "$exit_code" "validate_checksum_format accepts valid SHA1 (40 hex chars)"
}

test_validate_checksum_format_sha1_invalid() {
    local bad_sha1="tooshort"

    local exit_code=0
    _run_fetch_subshell "validate_checksum_format '$bad_sha1' 'sha1'" || exit_code=$?

    assert_equals "1" "$exit_code" "validate_checksum_format rejects invalid SHA1"
}

test_validate_checksum_format_unknown_type() {
    local some_hash="a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"

    local exit_code=0
    _run_fetch_subshell "validate_checksum_format '$some_hash' 'md5'" || exit_code=$?

    assert_equals "1" "$exit_code" "validate_checksum_format rejects unknown hash type"
}

test_validate_checksum_format_empty() {
    local exit_code=0
    _run_fetch_subshell "validate_checksum_format '' 'sha256'" || exit_code=$?

    assert_equals "1" "$exit_code" "validate_checksum_format rejects empty checksum"
}

# ============================================================================
# Functional Tests - _is_partial_version()
# ============================================================================

test_is_partial_version_xy() {
    local exit_code=0
    _run_fetch_subshell "_is_partial_version '1.23'" || exit_code=$?

    assert_equals "0" "$exit_code" "_is_partial_version returns 0 for '1.23' (partial)"
}

test_is_partial_version_xyz() {
    local exit_code=0
    _run_fetch_subshell "_is_partial_version '1.23.5'" || exit_code=$?

    assert_equals "1" "$exit_code" "_is_partial_version returns 1 for '1.23.5' (full)"
}

test_is_partial_version_major_only() {
    local exit_code=0
    _run_fetch_subshell "_is_partial_version '22'" || exit_code=$?

    assert_equals "1" "$exit_code" "_is_partial_version returns 1 for '22' (no dots)"
}

test_is_partial_version_many_dots() {
    local exit_code=0
    _run_fetch_subshell "_is_partial_version '1.2.3.4'" || exit_code=$?

    assert_equals "1" "$exit_code" "_is_partial_version returns 1 for '1.2.3.4' (too many dots)"
}

# ============================================================================
# Static Analysis - Export checks
# ============================================================================

test_exports_fetch_go_checksum() {
    assert_file_contains "$SOURCE_FILE" "export -f fetch_go_checksum" \
        "fetch_go_checksum is exported"
}

test_exports_fetch_github_checksums_txt() {
    assert_file_contains "$SOURCE_FILE" "export -f fetch_github_checksums_txt" \
        "fetch_github_checksums_txt is exported"
}

test_exports_fetch_github_sha256_file() {
    assert_file_contains "$SOURCE_FILE" "export -f fetch_github_sha256_file" \
        "fetch_github_sha256_file is exported"
}

test_exports_fetch_github_sha512_file() {
    assert_file_contains "$SOURCE_FILE" "export -f fetch_github_sha512_file" \
        "fetch_github_sha512_file is exported"
}

test_exports_fetch_ruby_checksum() {
    assert_file_contains "$SOURCE_FILE" "export -f fetch_ruby_checksum" \
        "fetch_ruby_checksum is exported"
}

test_exports_validate_checksum_format() {
    assert_file_contains "$SOURCE_FILE" "export -f validate_checksum_format" \
        "validate_checksum_format is exported"
}

test_sha256_regex_64_hex() {
    # The source should validate SHA256 as exactly 64 hex characters
    assert_file_contains "$SOURCE_FILE" '\[a-fA-F0-9\]{64}' \
        "Source validates SHA256 as 64 hex characters"
}

test_sha512_regex_128_hex() {
    # The source should validate SHA512 as exactly 128 hex characters
    assert_file_contains "$SOURCE_FILE" '\[a-fA-F0-9\]{128}' \
        "Source validates SHA512 as 128 hex characters"
}

# ============================================================================
# Run all tests
# ============================================================================

# Static analysis - function definitions
run_test_with_setup test_strict_mode "Script uses strict mode"
run_test_with_setup test_defines_fetch_go_checksum "Defines fetch_go_checksum function"
run_test_with_setup test_defines_fetch_github_checksums_txt "Defines fetch_github_checksums_txt function"
run_test_with_setup test_defines_fetch_github_sha256_file "Defines fetch_github_sha256_file function"
run_test_with_setup test_defines_fetch_github_sha512_file "Defines fetch_github_sha512_file function"
run_test_with_setup test_defines_fetch_ruby_checksum "Defines fetch_ruby_checksum function"
run_test_with_setup test_defines_fetch_maven_sha1 "Defines fetch_maven_sha1 function"
run_test_with_setup test_defines_validate_checksum_format "Defines validate_checksum_format function"
run_test_with_setup test_defines_is_partial_version "Defines _is_partial_version function"
run_test_with_setup test_defines_calculate_checksum_sha256 "Defines calculate_checksum_sha256 function"

# Static analysis - URL patterns
run_test_with_setup test_go_url_pattern "Go uses go.dev URL"
run_test_with_setup test_ruby_url_pattern "Ruby uses ruby-lang.org URL"
run_test_with_setup test_curl_timeout_configured "Curl includes connection timeout"
run_test_with_setup test_curl_max_time_configured "Curl includes max-time timeout"

# validate_checksum_format
run_test_with_setup test_validate_checksum_format_sha256_valid "SHA256 valid: 64 hex chars accepted"
run_test_with_setup test_validate_checksum_format_sha256_invalid_short "SHA256 invalid: short string rejected"
run_test_with_setup test_validate_checksum_format_sha256_invalid_chars "SHA256 invalid: non-hex chars rejected"
run_test_with_setup test_validate_checksum_format_sha512_valid "SHA512 valid: 128 hex chars accepted"
run_test_with_setup test_validate_checksum_format_sha512_invalid_short "SHA512 invalid: 64-char string rejected"
run_test_with_setup test_validate_checksum_format_sha1_valid "SHA1 valid: 40 hex chars accepted"
run_test_with_setup test_validate_checksum_format_sha1_invalid "SHA1 invalid: short string rejected"
run_test_with_setup test_validate_checksum_format_unknown_type "Unknown hash type rejected"
run_test_with_setup test_validate_checksum_format_empty "Empty checksum rejected"

# _is_partial_version
run_test_with_setup test_is_partial_version_xy "Partial version: X.Y is partial"
run_test_with_setup test_is_partial_version_xyz "Full version: X.Y.Z is not partial"
run_test_with_setup test_is_partial_version_major_only "Major only: no dots is not partial"
run_test_with_setup test_is_partial_version_many_dots "Many dots: X.Y.Z.W is not partial"

# Export checks
run_test_with_setup test_exports_fetch_go_checksum "Exports fetch_go_checksum"
run_test_with_setup test_exports_fetch_github_checksums_txt "Exports fetch_github_checksums_txt"
run_test_with_setup test_exports_fetch_github_sha256_file "Exports fetch_github_sha256_file"
run_test_with_setup test_exports_fetch_github_sha512_file "Exports fetch_github_sha512_file"
run_test_with_setup test_exports_fetch_ruby_checksum "Exports fetch_ruby_checksum"
run_test_with_setup test_exports_validate_checksum_format "Exports validate_checksum_format"
run_test_with_setup test_sha256_regex_64_hex "Source validates SHA256 as 64 hex chars"
run_test_with_setup test_sha512_regex_128_hex "Source validates SHA512 as 128 hex chars"

# Generate test report
generate_report
