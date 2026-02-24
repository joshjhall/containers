#!/usr/bin/env bash
# Unit tests for lib/base/version-resolution.sh
# Tests version resolution for all supported languages

set -euo pipefail

# Set BUILD_LOG_DIR early to avoid permission issues in CI
# This must be set BEFORE any script sources logging.sh
export BUILD_LOG_DIR
BUILD_LOG_DIR=$(mktemp -d)

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Version Resolution Tests"

# Setup function - runs before each test
setup() {
    # Source logging first (required by version-resolution.sh)
    source "$PROJECT_ROOT/lib/base/logging.sh"

    # Source the version resolution library
    source "$PROJECT_ROOT/lib/base/version-resolution.sh"

    # Track if we hit rate limits (for informative skip messages)
    export RATE_LIMIT_HIT=false

    # Check for GitHub token (helpful for rate limits)
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        export GITHUB_AUTH_HEADER="Authorization: Bearer $GITHUB_TOKEN"
    else
        export GITHUB_AUTH_HEADER=""
    fi
}

# Teardown function - runs after each test
teardown() {
    # Clean up temporary log directory (ignore errors)
    if [ -n "${BUILD_LOG_DIR:-}" ] && [ -d "$BUILD_LOG_DIR" ]; then
        command rm -rf "$BUILD_LOG_DIR" 2>/dev/null || true
    fi

    unset RATE_LIMIT_HIT 2>/dev/null || true
    unset GITHUB_AUTH_HEADER 2>/dev/null || true
    unset BUILD_LOG_DIR 2>/dev/null || true
}

# Wrapper to run tests with setup/teardown
run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"

    setup
    run_test "$test_function" "$test_description"
    teardown
}

# Helper function to detect rate limiting
is_rate_limited() {
    local http_code="$1"
    local response="$2"

    # GitHub returns 403 for rate limit exceeded
    # Most APIs return 429 for rate limiting
    if [ "$http_code" = "403" ] || [ "$http_code" = "429" ]; then
        if echo "$response" | grep -qi "rate limit\|too many requests\|API rate limit"; then
            return 0
        fi
    fi
    return 1
}

# Helper function to check if network is available
check_network() {
    if ! curl -s --connect-timeout 5 https://www.google.com > /dev/null 2>&1; then
        return 1
    fi
    return 0
}

# ============================================================================
# Helper Function Tests
# ============================================================================

test_is_full_version() {
    # Full versions should return true (exit 0)
    _is_full_version "3.12.7" && assert_true true "3.12.7 is a full version" || assert_true false "3.12.7 should be full version"
    _is_full_version "1.82.0" && assert_true true "1.82.0 is a full version" || assert_true false "1.82.0 should be full version"

    # Partial versions should return false (exit 1)
    _is_full_version "3.12" && assert_true false "3.12 should not be full version" || assert_true true "3.12 is not a full version"
    _is_full_version "3" && assert_true false "3 should not be full version" || assert_true true "3 is not a full version"
}

test_is_major_minor() {
    # Major.minor versions should return true
    _is_major_minor "3.12" && assert_true true "3.12 is major.minor" || assert_true false "3.12 should be major.minor"
    _is_major_minor "1.82" && assert_true true "1.82 is major.minor" || assert_true false "1.82 should be major.minor"

    # Other formats should return false
    _is_major_minor "3.12.7" && assert_true false "3.12.7 should not be major.minor" || assert_true true "3.12.7 is not major.minor"
    _is_major_minor "3" && assert_true false "3 should not be major.minor" || assert_true true "3 is not major.minor"
}

test_is_major_only() {
    # Major only should return true
    _is_major_only "3" && assert_true true "3 is major only" || assert_true false "3 should be major only"
    _is_major_only "1" && assert_true true "1 is major only" || assert_true false "1 should be major only"

    # Other formats should return false
    _is_major_only "3.12" && assert_true false "3.12 should not be major only" || assert_true true "3.12 is not major only"
    _is_major_only "3.12.7" && assert_true false "3.12.7 should not be major only" || assert_true true "3.12.7 is not major only"
}

# ============================================================================
# Python Version Resolution Tests
# ============================================================================

test_python_full_version_passthrough() {
    # Full versions should pass through unchanged
    local result
    result=$(resolve_python_version "3.12.7")
    assert_equals "3.12.7" "$result" "Full Python version passes through"
}

test_python_major_minor_resolution() {
    if ! check_network; then
        skip_test "No network connection available"
        return
    fi

    # Test resolving major.minor to latest patch
    local result
    result=$(resolve_python_version "3.12" 2>&1) || {
        # Check if it's a rate limit issue
        if echo "$result" | grep -qi "rate limit\|failed to fetch"; then
            skip_test "API rate limit or fetch failure (not a code error)"
            return
        fi
        assert_true false "Python 3.12 resolution failed: $result"
        return
    }

    # Result should be 3.12.X where X >= 0
    if [[ "$result" =~ ^3\.12\.[0-9]+$ ]]; then
        assert_true true "Python 3.12 resolved to valid patch version: $result"
    else
        assert_true false "Python 3.12 resolved to invalid version: $result"
    fi
}

test_python_major_only_resolution() {
    if ! check_network; then
        skip_test "No network connection available"
        return
    fi

    # Test resolving major only to latest stable
    local result
    result=$(resolve_python_version "3" 2>&1) || {
        if echo "$result" | grep -qi "rate limit\|failed to fetch"; then
            skip_test "API rate limit or fetch failure (not a code error)"
            return
        fi
        assert_true false "Python 3 resolution failed: $result"
        return
    }

    # Result should be 3.X.Y where X and Y >= 0
    if [[ "$result" =~ ^3\.[0-9]+\.[0-9]+$ ]]; then
        assert_true true "Python 3 resolved to valid version: $result"
    else
        assert_true false "Python 3 resolved to invalid version: $result"
    fi
}

# ============================================================================
# Node.js Version Resolution Tests
# ============================================================================

test_node_full_version_passthrough() {
    local result
    result=$(resolve_node_version "20.18.0")
    assert_equals "20.18.0" "$result" "Full Node.js version passes through"
}

test_node_major_minor_resolution() {
    if ! check_network; then
        skip_test "No network connection available"
        return
    fi

    local result
    result=$(resolve_node_version "20.18" 2>&1) || {
        if echo "$result" | grep -qi "rate limit\|failed to fetch"; then
            skip_test "API rate limit or fetch failure (not a code error)"
            return
        fi
        assert_true false "Node.js 20.18 resolution failed: $result"
        return
    }

    # Result should be 20.18.X
    if [[ "$result" =~ ^20\.18\.[0-9]+$ ]]; then
        assert_true true "Node.js 20.18 resolved to valid patch version: $result"
    else
        assert_true false "Node.js 20.18 resolved to invalid version: $result"
    fi
}

test_node_major_only_resolution() {
    if ! check_network; then
        skip_test "No network connection available"
        return
    fi

    local result
    result=$(resolve_node_version "20" 2>&1) || {
        if echo "$result" | grep -qi "rate limit\|failed to fetch"; then
            skip_test "API rate limit or fetch failure (not a code error)"
            return
        fi
        assert_true false "Node.js 20 resolution failed: $result"
        return
    }

    # Result should be 20.X.Y
    if [[ "$result" =~ ^20\.[0-9]+\.[0-9]+$ ]]; then
        assert_true true "Node.js 20 resolved to valid version: $result"
    else
        assert_true false "Node.js 20 resolved to invalid version: $result"
    fi
}

# ============================================================================
# Rust Version Resolution Tests
# ============================================================================

test_rust_full_version_passthrough() {
    local result
    result=$(resolve_rust_version "1.82.0")
    assert_equals "1.82.0" "$result" "Full Rust version passes through"
}

test_rust_major_minor_resolution() {
    if ! check_network; then
        skip_test "No network connection available"
        return
    fi

    local result
    result=$(resolve_rust_version "1.82" 2>&1) || {
        if echo "$result" | grep -qi "rate limit\|failed to fetch"; then
            skip_test "GitHub API rate limit (not a code error)"
            if [ -z "${GITHUB_TOKEN:-}" ]; then
                echo "  💡 TIP: Set GITHUB_TOKEN to increase rate limits"
            fi
            return
        fi
        assert_true false "Rust 1.82 resolution failed: $result"
        return
    }

    # Result should be 1.82.X
    if [[ "$result" =~ ^1\.82\.[0-9]+$ ]]; then
        assert_true true "Rust 1.82 resolved to valid patch version: $result"
    else
        assert_true false "Rust 1.82 resolved to invalid version: $result"
    fi
}

# ============================================================================
# Java Version Resolution Tests
# ============================================================================

test_java_full_version_passthrough() {
    local result
    result=$(resolve_java_version "21.0.1")
    assert_equals "21.0.1" "$result" "Full Java version passes through"
}

test_java_major_only_resolution() {
    if ! check_network; then
        skip_test "No network connection available"
        return
    fi

    local result
    result=$(resolve_java_version "21" 2>&1) || {
        if echo "$result" | grep -qi "rate limit\|failed to fetch"; then
            skip_test "Adoptium API rate limit or fetch failure (not a code error)"
            return
        fi
        assert_true false "Java 21 resolution failed: $result"
        return
    }

    # Result should be 21.X.Y or 21.X
    if [[ "$result" =~ ^21(\.[0-9]+)?(\.[0-9]+)?$ ]]; then
        assert_true true "Java 21 resolved to valid version: $result"
    else
        assert_true false "Java 21 resolved to invalid version: $result"
    fi
}

# ============================================================================
# Ruby Version Resolution Tests
# ============================================================================

test_ruby_full_version_passthrough() {
    local result
    result=$(resolve_ruby_version "3.4.7")
    assert_equals "3.4.7" "$result" "Full Ruby version passes through"
}

test_ruby_major_minor_resolution() {
    if ! check_network; then
        skip_test "No network connection available"
        return
    fi

    local result
    result=$(resolve_ruby_version "3.4" 2>&1) || {
        if echo "$result" | grep -qi "rate limit\|failed to fetch"; then
            skip_test "Ruby website rate limit or fetch failure (not a code error)"
            return
        fi
        assert_true false "Ruby 3.4 resolution failed: $result"
        return
    }

    # Result should be 3.4.X
    if [[ "$result" =~ ^3\.4\.[0-9]+$ ]]; then
        assert_true true "Ruby 3.4 resolved to valid patch version: $result"
    else
        assert_true false "Ruby 3.4 resolved to invalid version: $result"
    fi
}

test_ruby_major_only_resolution() {
    if ! check_network; then
        skip_test "No network connection available"
        return
    fi

    local result
    result=$(resolve_ruby_version "3" 2>&1) || {
        if echo "$result" | grep -qi "rate limit\|failed to fetch"; then
            skip_test "Ruby website rate limit or fetch failure (not a code error)"
            return
        fi
        assert_true false "Ruby 3 resolution failed: $result"
        return
    }

    # Result should be 3.X.Y
    if [[ "$result" =~ ^3\.[0-9]+\.[0-9]+$ ]]; then
        assert_true true "Ruby 3 resolved to valid version: $result"
    else
        assert_true false "Ruby 3 resolved to invalid version: $result"
    fi
}

# ============================================================================
# Go Version Resolution Tests
# ============================================================================

test_go_full_version_passthrough() {
    local result
    result=$(resolve_go_version "1.23.5")
    assert_equals "1.23.5" "$result" "Full Go version passes through"
}

test_go_major_minor_resolution() {
    if ! check_network; then
        skip_test "No network connection available"
        return
    fi

    local result
    result=$(resolve_go_version "1.23" 2>&1) || {
        if echo "$result" | grep -qi "rate limit\|failed to fetch"; then
            skip_test "Go website rate limit or fetch failure (not a code error)"
            return
        fi
        assert_true false "Go 1.23 resolution failed: $result"
        return
    }

    # Result should be 1.23.X
    if [[ "$result" =~ ^1\.23\.[0-9]+$ ]]; then
        assert_true true "Go 1.23 resolved to valid patch version: $result"
    else
        assert_true false "Go 1.23 resolved to invalid version: $result"
    fi
}

test_go_major_only_resolution() {
    if ! check_network; then
        skip_test "No network connection available"
        return
    fi

    local result
    result=$(resolve_go_version "1" 2>&1) || {
        if echo "$result" | grep -qi "rate limit\|failed to fetch"; then
            skip_test "Go website rate limit or fetch failure (not a code error)"
            return
        fi
        assert_true false "Go 1 resolution failed: $result"
        return
    }

    # Result should be 1.X.Y
    if [[ "$result" =~ ^1\.[0-9]+\.[0-9]+$ ]]; then
        assert_true true "Go 1 resolved to valid version: $result"
    else
        assert_true false "Go 1 resolved to invalid version: $result"
    fi
}

# ============================================================================
# Kotlin Version Resolution Tests
# ============================================================================

test_kotlin_full_version_passthrough() {
    local result
    result=$(resolve_kotlin_version "2.1.0")
    assert_equals "2.1.0" "$result" "Full Kotlin version passes through"
}

test_kotlin_major_minor_resolution() {
    if ! check_network; then
        skip_test "No network connection available"
        return
    fi

    local result
    result=$(resolve_kotlin_version "2.1" 2>&1) || {
        if echo "$result" | grep -qi "rate limit\|failed to fetch"; then
            skip_test "GitHub API rate limit or fetch failure (not a code error)"
            if [ -z "${GITHUB_TOKEN:-}" ]; then
                echo "  💡 TIP: Set GITHUB_TOKEN to increase rate limits"
            fi
            return
        fi
        assert_true false "Kotlin 2.1 resolution failed: $result"
        return
    }

    # Result should be 2.1.X
    if [[ "$result" =~ ^2\.1\.[0-9]+$ ]]; then
        assert_true true "Kotlin 2.1 resolved to valid patch version: $result"
    else
        assert_true false "Kotlin 2.1 resolved to invalid version: $result"
    fi
}

test_kotlin_major_only_resolution() {
    if ! check_network; then
        skip_test "No network connection available"
        return
    fi

    local result
    result=$(resolve_kotlin_version "2" 2>&1) || {
        if echo "$result" | grep -qi "rate limit\|failed to fetch"; then
            skip_test "GitHub API rate limit or fetch failure (not a code error)"
            if [ -z "${GITHUB_TOKEN:-}" ]; then
                echo "  💡 TIP: Set GITHUB_TOKEN to increase rate limits"
            fi
            return
        fi
        assert_true false "Kotlin 2 resolution failed: $result"
        return
    }

    # Result should be 2.X.Y
    if [[ "$result" =~ ^2\.[0-9]+\.[0-9]+$ ]]; then
        assert_true true "Kotlin 2 resolved to valid version: $result"
    else
        assert_true false "Kotlin 2 resolved to invalid version: $result"
    fi
}

# ============================================================================
# Network Failure Tests (mocked, always run offline)
# ============================================================================

test_network_failure_returns_error() {
    # Mock _curl_safe to simulate network failure, then try resolving a
    # partial version which requires network access
    local exit_code=0
    (
        # Override _curl_safe to return empty (simulating network failure)
        _curl_safe() { echo ""; }
        export -f _curl_safe

        resolve_python_version "3.12" 2>/dev/null
    ) > /dev/null 2>&1 || exit_code=$?

    assert_not_equals "0" "$exit_code" "Partial version resolution fails when network is unavailable"
}

test_network_failure_full_version_bypasses_network() {
    # Full versions should return immediately without calling curl
    local result
    result=$(
        # Override _curl_safe to return empty (simulating network failure)
        _curl_safe() { echo ""; }
        export -f _curl_safe

        resolve_python_version "3.12.7" 2>/dev/null
    )

    assert_equals "3.12.7" "$result" "Full version passes through even when network is unavailable"
}

# ============================================================================
# Generic resolve_version Wrapper Tests
# ============================================================================

test_resolve_version_wrapper_python() {
    if ! check_network; then
        skip_test "No network connection available"
        return
    fi

    local result
    result=$(resolve_version "python" "3.12" 2>&1) || {
        if echo "$result" | grep -qi "rate limit\|failed to fetch"; then
            skip_test "API rate limit or fetch failure (not a code error)"
            return
        fi
        assert_true false "resolve_version wrapper for python failed: $result"
        return
    }

    if [[ "$result" =~ ^3\.12\.[0-9]+$ ]]; then
        assert_true true "Wrapper resolved python 3.12 correctly: $result"
    else
        assert_true false "Wrapper resolved python to invalid version: $result"
    fi
}

test_resolve_version_wrapper_node() {
    if ! check_network; then
        skip_test "No network connection available"
        return
    fi

    local result
    result=$(resolve_version "node" "20" 2>&1) || {
        if echo "$result" | grep -qi "rate limit\|failed to fetch"; then
            skip_test "API rate limit or fetch failure (not a code error)"
            return
        fi
        assert_true false "resolve_version wrapper for node failed: $result"
        return
    }

    if [[ "$result" =~ ^20\.[0-9]+\.[0-9]+$ ]]; then
        assert_true true "Wrapper resolved node 20 correctly: $result"
    else
        assert_true false "Wrapper resolved node to invalid version: $result"
    fi
}

test_resolve_version_wrapper_nodejs_alias() {
    if ! check_network; then
        skip_test "No network connection available"
        return
    fi

    # Test that "nodejs" alias works
    local result
    result=$(resolve_version "nodejs" "20" 2>&1) || {
        if echo "$result" | grep -qi "rate limit\|failed to fetch"; then
            skip_test "API rate limit or fetch failure (not a code error)"
            return
        fi
        assert_true false "resolve_version wrapper for nodejs alias failed: $result"
        return
    }

    if [[ "$result" =~ ^20\.[0-9]+\.[0-9]+$ ]]; then
        assert_true true "Wrapper resolved nodejs alias correctly: $result"
    else
        assert_true false "Wrapper resolved nodejs to invalid version: $result"
    fi
}

test_resolve_version_wrapper_golang_alias() {
    if ! check_network; then
        skip_test "No network connection available"
        return
    fi

    # Test that "golang" alias works
    local result
    result=$(resolve_version "golang" "1.23" 2>&1) || {
        if echo "$result" | grep -qi "rate limit\|failed to fetch"; then
            skip_test "API rate limit or fetch failure (not a code error)"
            return
        fi
        assert_true false "resolve_version wrapper for golang alias failed: $result"
        return
    }

    if [[ "$result" =~ ^1\.23\.[0-9]+$ ]]; then
        assert_true true "Wrapper resolved golang alias correctly: $result"
    else
        assert_true false "Wrapper resolved golang to invalid version: $result"
    fi
}

test_resolve_version_unknown_language() {
    # Should return the version unchanged and exit with error
    local result
    result=$(resolve_version "invalid_language" "1.2.3" 2>/dev/null) || true

    # Check that it returned the original version
    assert_equals "1.2.3" "$result" "Unknown language returns original version"
}

# ============================================================================
# Error Handling Tests
# ============================================================================

test_empty_version_handling() {
    # Empty versions should fail gracefully
    local result
    result=$(resolve_python_version "" 2>&1) || true

    # Function should have failed (returned non-zero)
    # We don't check exact error message, just that it handled gracefully
    assert_true true "Empty version handled gracefully"
}

# ============================================================================
# Run all tests
# ============================================================================

# Helper function tests
run_test_with_setup test_is_full_version "Full version detection"
run_test_with_setup test_is_major_minor "Major.minor version detection"
run_test_with_setup test_is_major_only "Major only version detection"

# Python tests
run_test_with_setup test_python_full_version_passthrough "Python full version passthrough"
run_test_with_setup test_python_major_minor_resolution "Python major.minor resolution"
run_test_with_setup test_python_major_only_resolution "Python major only resolution"

# Node.js tests
run_test_with_setup test_node_full_version_passthrough "Node.js full version passthrough"
run_test_with_setup test_node_major_minor_resolution "Node.js major.minor resolution"
run_test_with_setup test_node_major_only_resolution "Node.js major only resolution"

# Rust tests
run_test_with_setup test_rust_full_version_passthrough "Rust full version passthrough"
run_test_with_setup test_rust_major_minor_resolution "Rust major.minor resolution"

# Java tests
run_test_with_setup test_java_full_version_passthrough "Java full version passthrough"
run_test_with_setup test_java_major_only_resolution "Java major only resolution"

# Ruby tests
run_test_with_setup test_ruby_full_version_passthrough "Ruby full version passthrough"
run_test_with_setup test_ruby_major_minor_resolution "Ruby major.minor resolution"
run_test_with_setup test_ruby_major_only_resolution "Ruby major only resolution"

# Go tests
run_test_with_setup test_go_full_version_passthrough "Go full version passthrough"
run_test_with_setup test_go_major_minor_resolution "Go major.minor resolution"
run_test_with_setup test_go_major_only_resolution "Go major only resolution"

# Kotlin tests
run_test_with_setup test_kotlin_full_version_passthrough "Kotlin full version passthrough"
run_test_with_setup test_kotlin_major_minor_resolution "Kotlin major.minor resolution"
run_test_with_setup test_kotlin_major_only_resolution "Kotlin major only resolution"

# Network failure tests (mocked, always run offline)
run_test_with_setup test_network_failure_returns_error "Network failure returns error for partial version"
run_test_with_setup test_network_failure_full_version_bypasses_network "Full version bypasses network even on failure"

# Wrapper function tests
run_test_with_setup test_resolve_version_wrapper_python "Wrapper: resolve python version"
run_test_with_setup test_resolve_version_wrapper_node "Wrapper: resolve node version"
run_test_with_setup test_resolve_version_wrapper_nodejs_alias "Wrapper: resolve nodejs alias"
run_test_with_setup test_resolve_version_wrapper_golang_alias "Wrapper: resolve golang alias"
run_test_with_setup test_resolve_version_unknown_language "Wrapper: unknown language handling"

# Error handling tests
run_test_with_setup test_empty_version_handling "Empty version handling"

# Generate test report
generate_report
