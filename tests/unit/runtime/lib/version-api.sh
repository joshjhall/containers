#!/usr/bin/env bash
# Unit tests for lib/runtime/lib/version-api.sh
# Tests version comparison and registry query functions used by version-checking scripts

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Version API Tests"

# Source file under test
SOURCE_FILE="$PROJECT_ROOT/lib/runtime/lib/version-api.sh"

# Setup function - runs before each test
setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$RESULTS_DIR/test-version-api-$unique_id"
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

# Helper: run a subshell that sources version-api.sh and executes commands
# version-api.sh is self-contained (no source dependencies), so we can source it directly
_run_vapi_subshell() {
    bash -c "
        source '$SOURCE_FILE' >/dev/null 2>&1
        $1
    " 2>/dev/null
}

# Helper: run a subshell with mock curl/jq in PATH for testing registry functions
_run_vapi_with_mock_curl() {
    local mock_curl_body="$1"
    local commands="$2"
    bash -c "
        # Create mock curl
        mkdir -p '$TEST_TEMP_DIR/bin'
        command cat > '$TEST_TEMP_DIR/bin/curl' <<'MOCK_CURL'
#!/usr/bin/env bash
$mock_curl_body
MOCK_CURL
        chmod +x '$TEST_TEMP_DIR/bin/curl'

        # Put mock dir first in PATH so 'command curl' finds the mock
        export PATH='$TEST_TEMP_DIR/bin':\$PATH

        source '$SOURCE_FILE' >/dev/null 2>&1
        $commands
    " 2>/dev/null
}

# ============================================================================
# Static Analysis Tests
# ============================================================================

test_script_exists() {
    assert_file_exists "$SOURCE_FILE" "version-api.sh exists"
}

test_strict_mode() {
    assert_file_contains "$SOURCE_FILE" "set -euo pipefail" \
        "Script uses strict mode"
}

test_defines_compare_version() {
    assert_file_contains "$SOURCE_FILE" "compare_version()" \
        "Script defines compare_version function"
}

test_defines_get_github_release() {
    assert_file_contains "$SOURCE_FILE" "get_github_release()" \
        "Script defines get_github_release function"
}

test_defines_get_pypi_version() {
    assert_file_contains "$SOURCE_FILE" "get_pypi_version()" \
        "Script defines get_pypi_version function"
}

test_defines_get_crates_version() {
    assert_file_contains "$SOURCE_FILE" "get_crates_version()" \
        "Script defines get_crates_version function"
}

test_defines_get_rubygems_version() {
    assert_file_contains "$SOURCE_FILE" "get_rubygems_version()" \
        "Script defines get_rubygems_version function"
}

test_defines_get_cran_version() {
    assert_file_contains "$SOURCE_FILE" "get_cran_version()" \
        "Script defines get_cran_version function"
}

test_defines_extract_version() {
    assert_file_contains "$SOURCE_FILE" "extract_version()" \
        "Script defines extract_version function"
}

test_defines_vapi_grep_helper() {
    assert_file_contains "$SOURCE_FILE" "_vapi_grep()" \
        "Script defines _vapi_grep helper"
}

# ============================================================================
# Functional Tests - compare_version (no mocking needed, uses only sort -V)
# ============================================================================

test_compare_version_up_to_date() {
    local result
    result=$(_run_vapi_subshell "compare_version '1.2.3' '1.2.3'")
    assert_equals "up-to-date" "$result" "compare_version returns up-to-date for equal versions"
}

test_compare_version_unknown_literal() {
    local result
    result=$(_run_vapi_subshell "compare_version '1.2.3' 'unknown'")
    assert_equals "unknown" "$result" "compare_version returns unknown for 'unknown' latest"
}

test_compare_version_rate_limited() {
    local result
    result=$(_run_vapi_subshell "compare_version '1.2.3' 'rate-limited'")
    assert_equals "unknown" "$result" "compare_version returns unknown for 'rate-limited' latest"
}

test_compare_version_not_found() {
    local result
    result=$(_run_vapi_subshell "compare_version '1.2.3' 'not found'")
    assert_equals "unknown" "$result" "compare_version returns unknown for 'not found' latest"
}

test_compare_version_newer() {
    local result
    result=$(_run_vapi_subshell "compare_version '2.0.0' '1.9.0'")
    assert_equals "newer" "$result" "compare_version returns newer when current > latest"
}

test_compare_version_outdated() {
    local result
    result=$(_run_vapi_subshell "compare_version '1.0.0' '2.0.0'")
    assert_equals "outdated" "$result" "compare_version returns outdated when current < latest"
}

# ============================================================================
# Functional Tests - get_github_release with mock curl
# ============================================================================

test_github_release_normal() {
    local result
    result=$(_run_vapi_with_mock_curl \
        'echo "{\"tag_name\": \"v1.2.3\"}"' \
        "get_github_release 'sigstore/cosign'")
    assert_equals "v1.2.3" "$result" "get_github_release extracts tag_name from JSON"
}

test_github_release_rate_limited() {
    local result
    result=$(_run_vapi_with_mock_curl \
        'echo "{\"message\": \"API rate limit exceeded\"}"' \
        "get_github_release 'sigstore/cosign'")
    assert_equals "rate-limited" "$result" "get_github_release returns rate-limited on API limit"
}

# ============================================================================
# Functional Tests - get_pypi_version with mock curl
# ============================================================================

test_pypi_version_normal() {
    local result
    result=$(_run_vapi_with_mock_curl \
        'echo "{\"info\":{\"version\":\"3.0.1\"}}"' \
        "get_pypi_version 'requests'")
    assert_equals "3.0.1" "$result" "get_pypi_version extracts version from PyPI JSON"
}

# ============================================================================
# Functional Tests - get_crates_version with mock curl
# ============================================================================

test_crates_version_normal() {
    local result
    result=$(_run_vapi_with_mock_curl \
        'echo "{\"crate\":{\"max_version\":\"0.18.3\"}}"' \
        "get_crates_version 'ripgrep'")
    assert_equals "0.18.3" "$result" "get_crates_version extracts max_version from crates.io JSON"
}

# ============================================================================
# Run all tests
# ============================================================================

# Static analysis
run_test_with_setup test_script_exists "Script exists"
run_test_with_setup test_strict_mode "Script uses strict mode"
run_test_with_setup test_defines_compare_version "Defines compare_version function"
run_test_with_setup test_defines_get_github_release "Defines get_github_release function"
run_test_with_setup test_defines_get_pypi_version "Defines get_pypi_version function"
run_test_with_setup test_defines_get_crates_version "Defines get_crates_version function"
run_test_with_setup test_defines_get_rubygems_version "Defines get_rubygems_version function"
run_test_with_setup test_defines_get_cran_version "Defines get_cran_version function"
run_test_with_setup test_defines_extract_version "Defines extract_version function"
run_test_with_setup test_defines_vapi_grep_helper "Defines _vapi_grep helper"

# compare_version
run_test_with_setup test_compare_version_up_to_date "compare_version: equal versions are up-to-date"
run_test_with_setup test_compare_version_unknown_literal "compare_version: 'unknown' latest returns unknown"
run_test_with_setup test_compare_version_rate_limited "compare_version: 'rate-limited' latest returns unknown"
run_test_with_setup test_compare_version_not_found "compare_version: 'not found' latest returns unknown"
run_test_with_setup test_compare_version_newer "compare_version: current > latest returns newer"
run_test_with_setup test_compare_version_outdated "compare_version: current < latest returns outdated"

# Registry functions with mock curl
run_test_with_setup test_github_release_normal "get_github_release: extracts tag from JSON"
run_test_with_setup test_github_release_rate_limited "get_github_release: detects rate limiting"
run_test_with_setup test_pypi_version_normal "get_pypi_version: extracts version from JSON"
run_test_with_setup test_crates_version_normal "get_crates_version: extracts version from JSON"

# Generate test report
generate_report
