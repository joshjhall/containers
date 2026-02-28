#!/usr/bin/env bash
# Unit tests for bin/generate-release-notes.sh
# Tests release note extraction from CHANGELOG.md

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Bin Generate Release Notes Tests"

SCRIPT="$PROJECT_ROOT/bin/generate-release-notes.sh"

# Setup function - runs before each test
setup() {
    export TEST_TEMP_DIR
    TEST_TEMP_DIR=$(mktemp -d -t "release-notes-test-XXXXXX")

    # Build a fake project tree so the script's BIN_DIR/PROJECT_ROOT resolution
    # points at our temp CHANGELOG.
    export FAKE_PROJECT="$TEST_TEMP_DIR/project"
    mkdir -p "$FAKE_PROJECT/bin"

    # Symlink the real script into our fake bin/ directory
    ln -s "$SCRIPT" "$FAKE_PROJECT/bin/generate-release-notes.sh"

    # Create a synthetic CHANGELOG with multiple versions
    command cat > "$FAKE_PROJECT/CHANGELOG.md" <<'CHANGELOG'
# Changelog

## [2.0.0] - 2026-02-01

### Added

- Major new feature
- Breaking change

### Fixed

- Critical bug

## [1.1.0] - 2026-01-15

### Added

- Minor feature

## [1.0.0] - 2026-01-01

### Added

- Initial release
CHANGELOG
}

# Teardown function - runs after each test
teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ] && [ -d "$TEST_TEMP_DIR" ]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
    unset TEST_TEMP_DIR FAKE_PROJECT
}

# Test: Script exists and is executable
test_script_exists() {
    assert_file_exists "$SCRIPT"
    assert_executable "$SCRIPT"
}

# Test: Valid bash syntax
test_valid_syntax() {
    local exit_code=0
    bash -n "$SCRIPT" 2>/dev/null || exit_code=$?
    assert_equals "0" "$exit_code" "Script should have valid bash syntax"
}

# Test: No VERSION arg → exit 1
test_no_args_exits_1() {
    local exit_code=0
    "$SCRIPT" 2>/dev/null || exit_code=$?
    assert_equals "1" "$exit_code" "Script should exit 1 when no VERSION provided"
}

# Test: Missing CHANGELOG → exit 1
test_missing_changelog_exits_1() {
    # Create a bare project with bin/ but no CHANGELOG.md
    local bare_project="$TEST_TEMP_DIR/bare"
    mkdir -p "$bare_project/bin"
    ln -s "$SCRIPT" "$bare_project/bin/generate-release-notes.sh"

    local exit_code=0
    local output
    output=$("$bare_project/bin/generate-release-notes.sh" "1.0.0" 2>&1) || exit_code=$?
    assert_equals "1" "$exit_code" "Should exit 1 when CHANGELOG.md is missing"
    assert_contains "$output" "CHANGELOG.md not found" "Should report missing CHANGELOG"
}

# Test: Extracts correct version section
test_extracts_correct_section() {
    local output
    output=$("$FAKE_PROJECT/bin/generate-release-notes.sh" "2.0.0" 2>&1)

    assert_contains "$output" "Major new feature" "Should contain content from 2.0.0 section"
    assert_contains "$output" "Breaking change" "Should contain all items from 2.0.0"
    assert_contains "$output" "Critical bug" "Should include Fixed subsection"
    assert_not_contains "$output" "Minor feature" "Should not contain content from other versions"
    assert_not_contains "$output" "Initial release" "Should not contain content from 1.0.0"
}

# Test: Extracts last version (no next ## [ header after it)
test_extracts_last_version() {
    local output
    output=$("$FAKE_PROJECT/bin/generate-release-notes.sh" "1.0.0" 2>&1)

    assert_contains "$output" "Initial release" "Should extract content from the last version section"
    assert_not_contains "$output" "Major new feature" "Should not contain content from other versions"
}

# Test: Version not found → fallback message
test_version_not_found_fallback() {
    local output
    output=$("$FAKE_PROJECT/bin/generate-release-notes.sh" "9.9.9" 2>&1)

    assert_contains "$output" "Release v9.9.9" "Fallback should contain Release vVERSION"
    assert_contains "$output" "CHANGELOG.md" "Fallback should reference CHANGELOG.md"
}

# Test: Leading/trailing blank lines stripped from extracted output
test_no_leading_trailing_blanks() {
    local output
    output=$("$FAKE_PROJECT/bin/generate-release-notes.sh" "2.0.0" 2>&1)

    # Check that output doesn't start with a blank line
    local first_char
    first_char=$(printf '%s' "$output" | command head -c1)
    assert_not_equals "" "$first_char" "Output should not start with a blank line"

    # Check that output doesn't end with a blank line
    local last_line
    last_line=$(printf '%s' "$output" | command tail -n1)
    assert_not_empty "$last_line" "Output should not end with a blank line"
}

# Run all tests
run_test test_script_exists "Script exists and is executable"
run_test test_valid_syntax "Valid bash syntax"
run_test test_no_args_exits_1 "No VERSION arg exits with code 1"
run_test test_missing_changelog_exits_1 "Missing CHANGELOG exits with code 1"
run_test test_extracts_correct_section "Extracts correct version section"
run_test test_extracts_last_version "Extracts last version in file"
run_test test_version_not_found_fallback "Version not found produces fallback message"
run_test test_no_leading_trailing_blanks "No leading/trailing blank lines in output"

# Generate test report
generate_report
