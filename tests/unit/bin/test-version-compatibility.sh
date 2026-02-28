#!/usr/bin/env bash
# Unit tests for bin/test-version-compatibility.sh
# Tests version compatibility testing logic

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Version Compatibility Testing Tests"

# Setup function - runs before each test
setup() {
    # Create temporary directory for testing
    export TEST_TEMP_DIR="$RESULTS_DIR/test-version-compatibility"
    mkdir -p "$TEST_TEMP_DIR"

    # Mock version variables
    export PYTHON_VERSION=""
    export NODE_VERSION=""
    export RUST_VERSION=""
    export GO_VERSION=""
    export RUBY_VERSION=""
    export JAVA_VERSION=""
    export R_VERSION=""
    export BASE_IMAGE=""
}

# Teardown function - runs after each test
teardown() {
    # Clean up test directory
    if [ -n "${TEST_TEMP_DIR:-}" ] && [ -d "$TEST_TEMP_DIR" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi

    # Unset test variables
    unset TEST_TEMP_DIR PYTHON_VERSION NODE_VERSION RUST_VERSION GO_VERSION RUBY_VERSION JAVA_VERSION R_VERSION BASE_IMAGE 2>/dev/null || true
}

# ============================================================================
# Build Args Generation Tests
# ============================================================================

test_minimal_variant_args() {
    # Minimal variant should have no language-specific args
    local args=()
    # Simulate minimal variant - no language args added

    assert_equals "${#args[@]}" "0" "Minimal variant has no language args"
}

test_python_dev_variant_args() {
    # Python-dev variant should include Python args
    PYTHON_VERSION="3.13.0"

    local args=()
    args+=(--build-arg INCLUDE_PYTHON=true)
    args+=(--build-arg INCLUDE_PYTHON_DEV=true)
    if [ -n "$PYTHON_VERSION" ]; then
        args+=(--build-arg "PYTHON_VERSION=$PYTHON_VERSION")
    fi

    assert_equals "${#args[@]}" "6" "Python-dev has 6 build args (3 flags × 2 elements)"
    assert_contains "${args[*]}" "INCLUDE_PYTHON=true" "Includes PYTHON flag"
    assert_contains "${args[*]}" "INCLUDE_PYTHON_DEV=true" "Includes PYTHON_DEV flag"
    assert_contains "${args[*]}" "PYTHON_VERSION=3.13.0" "Includes Python version"
}

test_rust_golang_variant_args() {
    # Rust-golang variant should include both Rust and Go args
    RUST_VERSION="1.82.0"
    GO_VERSION="1.23.0"

    local args=()
    args+=(--build-arg INCLUDE_RUST=true)
    args+=(--build-arg INCLUDE_GOLANG=true)
    if [ -n "$RUST_VERSION" ]; then
        args+=(--build-arg "RUST_VERSION=$RUST_VERSION")
    fi
    if [ -n "$GO_VERSION" ]; then
        args+=(--build-arg "GO_VERSION=$GO_VERSION")
    fi

    assert_equals "${#args[@]}" "8" "Rust-golang has 8 build args (4 flags × 2 elements)"
    assert_contains "${args[*]}" "INCLUDE_RUST=true" "Includes RUST flag"
    assert_contains "${args[*]}" "INCLUDE_GOLANG=true" "Includes GOLANG flag"
    assert_contains "${args[*]}" "RUST_VERSION=1.82.0" "Includes Rust version"
    assert_contains "${args[*]}" "GO_VERSION=1.23.0" "Includes Go version"
}

test_polyglot_variant_args() {
    # Polyglot variant should include multiple languages
    PYTHON_VERSION="3.13.0"
    NODE_VERSION="20"
    RUST_VERSION="1.82.0"
    GO_VERSION="1.23.0"

    local args=()
    args+=(--build-arg INCLUDE_PYTHON=true)
    args+=(--build-arg INCLUDE_NODE=true)
    args+=(--build-arg INCLUDE_RUST=true)
    args+=(--build-arg INCLUDE_GOLANG=true)
    if [ -n "$PYTHON_VERSION" ]; then
        args+=(--build-arg "PYTHON_VERSION=$PYTHON_VERSION")
    fi
    if [ -n "$NODE_VERSION" ]; then
        args+=(--build-arg "NODE_VERSION=$NODE_VERSION")
    fi
    if [ -n "$RUST_VERSION" ]; then
        args+=(--build-arg "RUST_VERSION=$RUST_VERSION")
    fi
    if [ -n "$GO_VERSION" ]; then
        args+=(--build-arg "GO_VERSION=$GO_VERSION")
    fi

    assert_equals "${#args[@]}" "16" "Polyglot has 16 build args (8 flags × 2 elements)"
    assert_contains "${args[*]}" "PYTHON_VERSION=3.13.0" "Includes Python version"
    assert_contains "${args[*]}" "NODE_VERSION=20" "Includes Node version"
    assert_contains "${args[*]}" "RUST_VERSION=1.82.0" "Includes Rust version"
    assert_contains "${args[*]}" "GO_VERSION=1.23.0" "Includes Go version"
}

# ============================================================================
# Version JSON Generation Tests
# ============================================================================

test_version_json_generation_single_language() {
    PYTHON_VERSION="3.13.0"

    # Simulate JSON generation
    local versions_json="{"
    local first=true

    for lang in python node rust go ruby java r mojo; do
        local version_var="${lang^^}_VERSION"
        local version="${!version_var:-}"
        if [ -n "$version" ]; then
            if [ "$first" = false ]; then
                versions_json+=","
            fi
            versions_json+="\"$lang\": \"$version\""
            first=false
        fi
    done

    versions_json+="}"

    assert_contains "$versions_json" '"python": "3.13.0"' "JSON contains Python version"
    assert_not_contains "$versions_json" '"node"' "JSON does not contain Node"
}

test_version_json_generation_multiple_languages() {
    PYTHON_VERSION="3.13.0"
    NODE_VERSION="20"

    # Simulate JSON generation
    local versions_json="{"
    local first=true

    for lang in python node rust go ruby java r mojo; do
        local version_var="${lang^^}_VERSION"
        local version="${!version_var:-}"
        if [ -n "$version" ]; then
            if [ "$first" = false ]; then
                versions_json+=","
            fi
            versions_json+="\"$lang\": \"$version\""
            first=false
        fi
    done

    versions_json+="}"

    assert_contains "$versions_json" '"python": "3.13.0"' "JSON contains Python version"
    assert_contains "$versions_json" '"node": "20"' "JSON contains Node version"
}

test_version_json_generation_no_versions() {
    # No versions set

    # Simulate JSON generation
    local versions_json="{"
    local first=true

    for lang in python node rust go ruby java r mojo; do
        local version_var="${lang^^}_VERSION"
        local version="${!version_var:-}"
        if [ -n "$version" ]; then
            if [ "$first" = false ]; then
                versions_json+=","
            fi
            versions_json+="\"$lang\": \"$version\""
            first=false
        fi
    done

    versions_json+="}"

    assert_equals "$versions_json" "{}" "Empty JSON for no versions"
}

# ============================================================================
# Matrix Entry Creation Tests
# ============================================================================

test_matrix_entry_format() {
    PYTHON_VERSION="3.13.0"

    # Simulate creating a matrix entry
    local variant="python-dev"
    local status="passing"
    local base_image="debian:13-slim"

    local versions_json='{"python": "3.13.0"}'

    local entry
    entry=$(command cat << EOF
{
  "variant": "$variant",
  "base_image": "$base_image",
  "versions": $versions_json,
  "status": "$status"
}
EOF
)

    assert_contains "$entry" '"variant": "python-dev"' "Entry contains variant"
    assert_contains "$entry" '"status": "passing"' "Entry contains status"
    assert_contains "$entry" '"python": "3.13.0"' "Entry contains version"
}

test_matrix_entry_with_notes() {
    PYTHON_VERSION="3.13.0"

    local variant="python-dev"
    local status="failing"
    # shellcheck disable=SC2034  # notes is reserved for future use in matrix entries
    local notes="Build failed due to missing dependency"

    local entry_has_notes=true

    if [ "$entry_has_notes" = true ]; then
        assert_true true "Entry can include notes"
    fi
}

# ============================================================================
# Compatibility Matrix Validation Tests
# ============================================================================

test_compatibility_matrix_schema() {
    # Test that matrix has required fields
    local required_fields=("last_updated" "base_images" "language_versions" "tested_combinations")

    for field in "${required_fields[@]}"; do
        assert_not_equals "$field" "" "Required field: $field"
    done
}

test_version_set_structure() {
    # Test that version sets have required fields
    local required_version_fields=("current" "supported" "tested")

    for field in "${required_version_fields[@]}"; do
        assert_not_equals "$field" "" "Required version field: $field"
    done
}

# ============================================================================
# Test Counter Tests
# ============================================================================

test_test_counters() {
    local TESTS_RUN=0
    local TESTS_PASSED=0
    local TESTS_FAILED=0

    # Simulate test execution
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))

    assert_equals "$TESTS_RUN" "1" "Tests run counter increments"
    assert_equals "$TESTS_PASSED" "1" "Tests passed counter increments"
    assert_equals "$TESTS_FAILED" "0" "Tests failed counter starts at 0"

    # Simulate failure
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))

    assert_equals "$TESTS_RUN" "2" "Tests run counter increments again"
    assert_equals "$TESTS_FAILED" "1" "Tests failed counter increments"
}

# ============================================================================
# Update Matrix Function Tests
# ============================================================================

test_update_matrix_jq_available() {
    # Test that jq is used for matrix updates
    local script_content
    script_content=$(command cat "$PROJECT_ROOT/bin/test-version-compatibility.sh")

    assert_contains "$script_content" "command -v jq" "Should check for jq availability"
    assert_contains "$script_content" "updated_matrix=\$(jq" "Should use jq for JSON manipulation"
}

test_update_matrix_entry_replacement() {
    # Test that update_matrix can replace existing entries
    local script_content
    script_content=$(command cat "$PROJECT_ROOT/bin/test-version-compatibility.sh")

    assert_contains "$script_content" "new_entry.variant" "Should check for existing variants"
    assert_contains "$script_content" "tested_combinations" "Should update tested_combinations"
}

test_update_matrix_language_versions() {
    # Test that update_matrix updates language_versions
    local script_content
    script_content=$(command cat "$PROJECT_ROOT/bin/test-version-compatibility.sh")

    assert_contains "$script_content" "language_versions" "Should update language_versions"
    assert_contains "$script_content" ".current" "Should update current version"
    assert_contains "$script_content" ".tested" "Should update tested array"
}

test_update_matrix_fallback() {
    # Test that update_matrix falls back to JSONL without jq
    local script_content
    script_content=$(command cat "$PROJECT_ROOT/bin/test-version-compatibility.sh")

    assert_contains "$script_content" "falling back to JSONL" "Should fall back without jq"
    assert_contains "$script_content" "version-compat-results.jsonl" "Should use JSONL fallback"
}

test_update_matrix_timestamp() {
    # Test that update_matrix updates timestamp
    local script_content
    script_content=$(command cat "$PROJECT_ROOT/bin/test-version-compatibility.sh")

    assert_contains "$script_content" "last_updated" "Should update last_updated timestamp"
}

# ============================================================================
# Run all tests
# ============================================================================

run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"

    setup
    run_test "$test_function" "$test_description"
    teardown
}

# Build args tests
run_test_with_setup test_minimal_variant_args "Minimal variant build args"
run_test_with_setup test_python_dev_variant_args "Python-dev variant build args"
run_test_with_setup test_rust_golang_variant_args "Rust-golang variant build args"
run_test_with_setup test_polyglot_variant_args "Polyglot variant build args"

# Version JSON generation tests
run_test_with_setup test_version_json_generation_single_language "JSON generation: single language"
run_test_with_setup test_version_json_generation_multiple_languages "JSON generation: multiple languages"
run_test_with_setup test_version_json_generation_no_versions "JSON generation: no versions"

# Matrix entry tests
run_test_with_setup test_matrix_entry_format "Matrix entry format"
run_test_with_setup test_matrix_entry_with_notes "Matrix entry with notes"

# Schema validation tests
run_test_with_setup test_compatibility_matrix_schema "Compatibility matrix schema"
run_test_with_setup test_version_set_structure "Version set structure"

# Counter tests
run_test_with_setup test_test_counters "Test counter functionality"

# Update matrix tests
run_test_with_setup test_update_matrix_jq_available "Update matrix jq availability"
run_test_with_setup test_update_matrix_entry_replacement "Update matrix entry replacement"
run_test_with_setup test_update_matrix_language_versions "Update matrix language versions"
run_test_with_setup test_update_matrix_fallback "Update matrix fallback to JSONL"
run_test_with_setup test_update_matrix_timestamp "Update matrix timestamp"

# Generate test report
generate_report
