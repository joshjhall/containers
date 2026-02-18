#!/usr/bin/env bash
# Unit tests for bin/update-gpg-keys.sh
# Tests GPG key update script structure and content via static analysis

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Bin Update GPG Keys Tests"

SOURCE_FILE="$PROJECT_ROOT/bin/update-gpg-keys.sh"

# Setup function - runs before each test
setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$RESULTS_DIR/test-update-gpg-keys-$unique_id"
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
test_gpg_strict_mode() {
    assert_file_contains "$SOURCE_FILE" "set -euo pipefail" \
        "update-gpg-keys.sh should use strict mode"
}

# Test: Script defines update_python_keys function
test_gpg_defines_update_python_keys() {
    assert_file_contains "$SOURCE_FILE" "update_python_keys()" \
        "Should define update_python_keys function"
}

# Test: Script defines update_nodejs_keys function
test_gpg_defines_update_nodejs_keys() {
    assert_file_contains "$SOURCE_FILE" "update_nodejs_keys()" \
        "Should define update_nodejs_keys function"
}

# Test: Script defines update_hashicorp_keys function
test_gpg_defines_update_hashicorp_keys() {
    assert_file_contains "$SOURCE_FILE" "update_hashicorp_keys()" \
        "Should define update_hashicorp_keys function"
}

# Test: Script defines update_golang_keys function
test_gpg_defines_update_golang_keys() {
    assert_file_contains "$SOURCE_FILE" "update_golang_keys()" \
        "Should define update_golang_keys function"
}

# Test: Script defines main function
test_gpg_defines_main() {
    assert_file_contains "$SOURCE_FILE" "main()" \
        "Should define main function"
}

# ---------------------------------------------------------------------------
# Static analysis tests: Logging functions
# ---------------------------------------------------------------------------

# Test: Script defines log_info function
test_gpg_defines_log_info() {
    assert_file_contains "$SOURCE_FILE" "log_info()" \
        "Should define log_info function"
}

# Test: Script defines log_success function
test_gpg_defines_log_success() {
    assert_file_contains "$SOURCE_FILE" "log_success()" \
        "Should define log_success function"
}

# Test: Script defines log_warning function
test_gpg_defines_log_warning() {
    assert_file_contains "$SOURCE_FILE" "log_warning()" \
        "Should define log_warning function"
}

# Test: Script defines log_error function
test_gpg_defines_log_error() {
    assert_file_contains "$SOURCE_FILE" "log_error()" \
        "Should define log_error function"
}

# ---------------------------------------------------------------------------
# Static analysis tests: Key paths and constants
# ---------------------------------------------------------------------------

# Test: GPG_KEYS_DIR references lib/gpg-keys
test_gpg_keys_dir_path() {
    assert_file_contains "$SOURCE_FILE" "lib/gpg-keys" \
        "GPG_KEYS_DIR should reference lib/gpg-keys"
}

# Test: HashiCorp fingerprint constant
test_gpg_hashicorp_fingerprint() {
    assert_file_contains "$SOURCE_FILE" "C874011F0AB405110D02105534365D9472D7468F" \
        "Should contain HashiCorp expected fingerprint"
}

# Test: Golang fingerprint constant
test_gpg_golang_fingerprint() {
    assert_file_contains "$SOURCE_FILE" "EB4C1BFD4F042F6DDDCCEC917721F63BD38B4796" \
        "Should contain Golang expected fingerprint"
}

# ---------------------------------------------------------------------------
# Static analysis tests: Key source URLs
# ---------------------------------------------------------------------------

# Test: Python key URL for Thomas Wouters
test_gpg_python_url_wouters() {
    assert_file_contains "$SOURCE_FILE" "github.com/Yhg1s.gpg" \
        "Should fetch Thomas Wouters GPG key from GitHub"
}

# Test: Python key URL for Pablo Galindo
test_gpg_python_url_galindo() {
    assert_file_contains "$SOURCE_FILE" "keybase.io/pablogsal" \
        "Should fetch Pablo Galindo GPG key from Keybase"
}

# Test: Python key URL for Lukasz Langa
test_gpg_python_url_langa() {
    assert_file_contains "$SOURCE_FILE" "keybase.io/ambv" \
        "Should fetch Lukasz Langa GPG key from Keybase"
}

# Test: Node.js uses release-keys repository
test_gpg_nodejs_release_keys_repo() {
    assert_file_contains "$SOURCE_FILE" "release-keys" \
        "Should use nodejs release-keys repository"
}

# Test: HashiCorp key URL
test_gpg_hashicorp_key_url() {
    assert_file_contains "$SOURCE_FILE" "hashicorp.com/.well-known/pgp-key.txt" \
        "Should fetch HashiCorp key from official well-known URL"
}

# Test: Golang key URL
test_gpg_golang_key_url() {
    assert_file_contains "$SOURCE_FILE" "dl.google.com/linux/linux_signing_key.pub" \
        "Should fetch Google Linux signing key"
}

# ---------------------------------------------------------------------------
# Static analysis tests: Security and file handling
# ---------------------------------------------------------------------------

# Test: Handles 'all' keyword
test_gpg_handles_all_keyword() {
    assert_file_contains "$SOURCE_FILE" '"all"' \
        "Should handle 'all' keyword to update all languages"
}

# Test: Handles unknown language with warning
test_gpg_handles_unknown_language() {
    assert_file_contains "$SOURCE_FILE" "Unknown language" \
        "Should warn about unknown languages"
}

# Test: Uses chmod 700 for key directories
test_gpg_chmod_700_directories() {
    assert_file_contains "$SOURCE_FILE" "chmod 700" \
        "Should set key directories to chmod 700"
}

# Test: Uses chmod 600 for key files
test_gpg_chmod_600_files() {
    assert_file_contains "$SOURCE_FILE" "chmod 600" \
        "Should set key files to chmod 600"
}

# Test: Uses mktemp -d for temporary directories
test_gpg_uses_mktemp() {
    assert_file_contains "$SOURCE_FILE" "mktemp -d" \
        "Should use mktemp -d for secure temporary directories"
}

# ---------------------------------------------------------------------------
# Functional tests with mock commands
# ---------------------------------------------------------------------------

# Test: main() defaults to all languages when no arguments
test_gpg_main_defaults_to_all() {
    # Verify the default behavior in the script logic
    local script_content
    script_content=$(cat "$SOURCE_FILE")

    # Check for the logic that sets all languages when no args
    assert_contains "$script_content" 'languages=("python" "nodejs" "hashicorp" "golang")' \
        "main should default to all languages when no args given"
}

# Test: Script has valid bash syntax
test_gpg_script_syntax() {
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
run_test_with_setup test_gpg_strict_mode "Script uses set -euo pipefail"
run_test_with_setup test_gpg_defines_update_python_keys "Defines update_python_keys function"
run_test_with_setup test_gpg_defines_update_nodejs_keys "Defines update_nodejs_keys function"
run_test_with_setup test_gpg_defines_update_hashicorp_keys "Defines update_hashicorp_keys function"
run_test_with_setup test_gpg_defines_update_golang_keys "Defines update_golang_keys function"
run_test_with_setup test_gpg_defines_main "Defines main function"
run_test_with_setup test_gpg_defines_log_info "Defines log_info function"
run_test_with_setup test_gpg_defines_log_success "Defines log_success function"
run_test_with_setup test_gpg_defines_log_warning "Defines log_warning function"
run_test_with_setup test_gpg_defines_log_error "Defines log_error function"
run_test_with_setup test_gpg_keys_dir_path "GPG_KEYS_DIR references lib/gpg-keys"
run_test_with_setup test_gpg_hashicorp_fingerprint "HashiCorp fingerprint constant present"
run_test_with_setup test_gpg_golang_fingerprint "Golang fingerprint constant present"
run_test_with_setup test_gpg_python_url_wouters "Python key URL for Thomas Wouters"
run_test_with_setup test_gpg_python_url_galindo "Python key URL for Pablo Galindo"
run_test_with_setup test_gpg_python_url_langa "Python key URL for Lukasz Langa"
run_test_with_setup test_gpg_nodejs_release_keys_repo "Node.js uses release-keys repository"
run_test_with_setup test_gpg_hashicorp_key_url "HashiCorp key URL is correct"
run_test_with_setup test_gpg_golang_key_url "Golang key URL is correct"
run_test_with_setup test_gpg_handles_all_keyword "Handles 'all' keyword"
run_test_with_setup test_gpg_handles_unknown_language "Handles unknown language with warning"
run_test_with_setup test_gpg_chmod_700_directories "Uses chmod 700 for key directories"
run_test_with_setup test_gpg_chmod_600_files "Uses chmod 600 for key files"
run_test_with_setup test_gpg_uses_mktemp "Uses mktemp -d for temporary directories"
run_test_with_setup test_gpg_main_defaults_to_all "main() defaults to all languages when no args"
run_test_with_setup test_gpg_script_syntax "Script has valid bash syntax"

# Generate test report
generate_report
