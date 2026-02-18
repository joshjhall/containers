#!/usr/bin/env bash
# Unit tests for bin/update-checksums.sh
# Tests checksum update script structure and content via static analysis

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Bin Update Checksums Tests"

SOURCE_FILE="$PROJECT_ROOT/bin/update-checksums.sh"

# Setup function - runs before each test
setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$RESULTS_DIR/test-update-checksums-$unique_id"
    mkdir -p "$TEST_TEMP_DIR"
}

# Teardown function - runs after each test
teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
    unset TEST_TEMP_DIR 2>/dev/null || true
}

# Wrapper for running tests with setup/teardown
run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"

    setup
    run_test "$test_function" "$test_description"
    teardown
}

# ---------------------------------------------------------------------------
# Static analysis tests: Script structure
# ---------------------------------------------------------------------------

# Test: Script uses strict mode
test_checksums_strict_mode() {
    assert_file_contains "$SOURCE_FILE" "set -euo pipefail" \
        "update-checksums.sh should use strict mode"
}

# Test: Script defines update_checksum function
test_checksums_defines_update_checksum() {
    assert_file_contains "$SOURCE_FILE" "update_checksum()" \
        "Should define update_checksum function"
}

# Test: Script sources bin/lib/common.sh
test_checksums_sources_common() {
    assert_file_contains "$SOURCE_FILE" 'lib/common.sh' \
        "Should source common.sh utilities"
}

# Test: Script sources or references checksum-fetch.sh
test_checksums_sources_checksum_fetch() {
    assert_file_contains "$SOURCE_FILE" "checksum-fetch.sh" \
        "Should source or reference lib/features/lib/checksum-fetch.sh"
}

# ---------------------------------------------------------------------------
# Static analysis tests: Configuration and paths
# ---------------------------------------------------------------------------

# Test: CHECKSUMS_FILE references lib/checksums.json
test_checksums_file_path() {
    assert_file_contains "$SOURCE_FILE" "lib/checksums.json" \
        "CHECKSUMS_FILE should reference lib/checksums.json"
}

# Test: DRY_RUN variable initialization
test_checksums_dry_run_variable() {
    assert_file_contains "$SOURCE_FILE" "DRY_RUN=false" \
        "DRY_RUN should be initialized to false"
}

# Test: --dry-run flag handling
test_checksums_dry_run_flag() {
    assert_file_contains "$SOURCE_FILE" "DRY_RUN=true" \
        "Should set DRY_RUN=true when --dry-run flag is used"
}

# Test: --help flag handling
test_checksums_help_flag() {
    assert_file_contains "$SOURCE_FILE" "help)" \
        "Should handle --help flag"
}

# ---------------------------------------------------------------------------
# Static analysis tests: Backup and validation
# ---------------------------------------------------------------------------

# Test: Creates backup file with timestamp pattern
test_checksums_backup_file() {
    assert_file_contains "$SOURCE_FILE" ".backup-" \
        "Should create backup file with timestamp pattern"
}

# Test: SHA256 validation pattern (64 hex chars)
test_checksums_sha256_validation() {
    assert_file_contains "$SOURCE_FILE" "a-fA-F0-9" \
        "Should validate SHA256 checksum format with hex character class"
}

# Test: Processes nodejs language
test_checksums_processes_nodejs() {
    assert_file_contains "$SOURCE_FILE" "nodejs" \
        "Should process nodejs language checksums"
}

# Test: Processes golang language
test_checksums_processes_golang() {
    assert_file_contains "$SOURCE_FILE" "golang" \
        "Should process golang language checksums"
}

# Test: Processes ruby language
test_checksums_processes_ruby() {
    assert_file_contains "$SOURCE_FILE" "ruby" \
        "Should process ruby language checksums"
}

# ---------------------------------------------------------------------------
# Static analysis tests: Metadata and JSON handling
# ---------------------------------------------------------------------------

# Test: Updates metadata.generated timestamp
test_checksums_updates_metadata_timestamp() {
    assert_file_contains "$SOURCE_FILE" "metadata.generated" \
        "Should update metadata.generated timestamp"
}

# Test: Validates JSON with jq empty
test_checksums_validates_json() {
    assert_file_contains "$SOURCE_FILE" "jq empty" \
        "Should validate JSON with jq empty"
}

# Test: UPDATED_COUNT counter
test_checksums_updated_count() {
    assert_file_contains "$SOURCE_FILE" "UPDATED_COUNT" \
        "Should track UPDATED_COUNT counter"
}

# Test: FAILED_COUNT counter
test_checksums_failed_count() {
    assert_file_contains "$SOURCE_FILE" "FAILED_COUNT" \
        "Should track FAILED_COUNT counter"
}

# Test: Skips already-valid checksums (placeholder check)
test_checksums_skips_valid() {
    assert_file_contains "$SOURCE_FILE" "placeholder_to_be_added" \
        "Should skip placeholder_to_be_added checksums"
}

# ---------------------------------------------------------------------------
# Functional tests
# ---------------------------------------------------------------------------

# Test: Script has valid bash syntax
test_checksums_script_syntax() {
    if bash -n "$SOURCE_FILE" 2>/dev/null; then
        assert_true true "Script has valid bash syntax"
    else
        local errors
        errors=$(bash -n "$SOURCE_FILE" 2>&1 || true)
        echo "Bash syntax errors found:" >&2
        echo "$errors" >&2
        assert_true false "Script contains bash syntax errors"
    fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
run_test_with_setup test_checksums_strict_mode "Script uses set -euo pipefail"
run_test_with_setup test_checksums_defines_update_checksum "Defines update_checksum function"
run_test_with_setup test_checksums_sources_common "Sources bin/lib/common.sh"
run_test_with_setup test_checksums_sources_checksum_fetch "Sources or references checksum-fetch.sh"
run_test_with_setup test_checksums_file_path "CHECKSUMS_FILE references lib/checksums.json"
run_test_with_setup test_checksums_dry_run_variable "DRY_RUN initialized to false"
run_test_with_setup test_checksums_dry_run_flag "--dry-run flag sets DRY_RUN=true"
run_test_with_setup test_checksums_help_flag "--help flag is handled"
run_test_with_setup test_checksums_backup_file "Creates backup file with timestamp pattern"
run_test_with_setup test_checksums_sha256_validation "SHA256 validation uses 64 hex char pattern"
run_test_with_setup test_checksums_processes_nodejs "Processes nodejs language checksums"
run_test_with_setup test_checksums_processes_golang "Processes golang language checksums"
run_test_with_setup test_checksums_processes_ruby "Processes ruby language checksums"
run_test_with_setup test_checksums_updates_metadata_timestamp "Updates metadata.generated timestamp"
run_test_with_setup test_checksums_validates_json "Validates JSON with jq empty"
run_test_with_setup test_checksums_updated_count "Tracks UPDATED_COUNT counter"
run_test_with_setup test_checksums_failed_count "Tracks FAILED_COUNT counter"
run_test_with_setup test_checksums_skips_valid "Skips already-valid checksums"
run_test_with_setup test_checksums_script_syntax "Script has valid bash syntax"

# Generate test report
generate_report
