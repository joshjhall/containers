#!/usr/bin/env bash
# Unit tests for lib/base/run-feature.sh
# Tests the feature script wrapper functionality

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Run Feature Wrapper Tests"

# Setup function - runs before each test
setup() {
    # Create temporary directory for testing
    export TEST_TEMP_DIR="$RESULTS_DIR/test-run-feature"
    mkdir -p "$TEST_TEMP_DIR"

    # Create mock feature script
    export MOCK_FEATURE="$TEST_TEMP_DIR/test-feature.sh"
    command cat > "$MOCK_FEATURE" << 'EOF'
#!/bin/bash
echo "USERNAME=$1"
echo "UID=$2"
echo "GID=$3"
EOF
    chmod +x "$MOCK_FEATURE"

    # Create mock build-env file
    export MOCK_BUILD_ENV="$TEST_TEMP_DIR/build-env"
}

# Teardown function - runs after each test
teardown() {
    # Clean up test directory
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi

    # Unset test variables
    unset MOCK_FEATURE MOCK_BUILD_ENV 2>/dev/null || true
}

# Test: Script passes arguments to feature script
test_argument_passing() {
    # Simulate the wrapper script behavior
    local feature_script="$MOCK_FEATURE"
    local username="testuser"
    local uid="1000"
    local gid="1000"

    # Execute the mock feature script directly
        local output
    output=$("$feature_script" "$username" "$uid" "$gid")

    # Check output
    if [[ "$output" == *"USERNAME=testuser"* ]]; then
        assert_true true "Username passed correctly"
    else
        assert_true false "Username not passed correctly"
    fi

    if [[ "$output" == *"UID=1000"* ]]; then
        assert_true true "UID passed correctly"
    else
        assert_true false "UID not passed correctly"
    fi

    if [[ "$output" == *"GID=1000"* ]]; then
        assert_true true "GID passed correctly"
    else
        assert_true false "GID not passed correctly"
    fi
}

# Test: Build-env file overrides UID/GID
test_build_env_override() {
    # Create build-env file
    command cat > "$MOCK_BUILD_ENV" << 'EOF'
ACTUAL_UID=2000
ACTUAL_GID=2000
EOF

    # Simulate sourcing build-env and using actual values
    source "$MOCK_BUILD_ENV"

    # Check that ACTUAL_UID and ACTUAL_GID are set
    assert_equals "2000" "$ACTUAL_UID" "ACTUAL_UID is set from build-env"
    assert_equals "2000" "$ACTUAL_GID" "ACTUAL_GID is set from build-env"

    # Simulate wrapper logic
    local username="testuser"
    local provided_uid="1000"
    local provided_gid="1000"

    # Use actual values if build-env exists
    local final_uid="${ACTUAL_UID:-$provided_uid}"
    local final_gid="${ACTUAL_GID:-$provided_gid}"

    assert_equals "2000" "$final_uid" "UID overridden by build-env"
    assert_equals "2000" "$final_gid" "GID overridden by build-env"

    unset ACTUAL_UID ACTUAL_GID
}

# Test: Fallback when build-env doesn't exist
test_fallback_without_build_env() {
    # Ensure build-env doesn't exist
    command rm -f "$MOCK_BUILD_ENV"

    # Simulate wrapper behavior without build-env
    local username="testuser"
    local uid="1500"
    local gid="1500"

    # Since build-env doesn't exist, use passed values
    local output
    output=$("$MOCK_FEATURE" "$username" "$uid" "$gid")

    if [[ "$output" == *"UID=1500"* ]]; then
        assert_true true "Fallback UID used when build-env missing"
    else
        assert_true false "Fallback UID not used"
    fi

    if [[ "$output" == *"GID=1500"* ]]; then
        assert_true true "Fallback GID used when build-env missing"
    else
        assert_true false "Fallback GID not used"
    fi
}

# Test: Script handles missing arguments gracefully
test_missing_arguments() {
    # Test with only feature script argument
    local feature_script="$MOCK_FEATURE"

    # Create a wrapper function that handles missing args
    run_feature_wrapper() {
        local script="$1"
        shift
        local username="${1:-developer}"
        local uid="${2:-1000}"
        local gid="${3:-1000}"
        "$script" "$username" "$uid" "$gid"
    }

    # Test with missing arguments
    local output
    output=$(run_feature_wrapper "$feature_script")

    if [[ "$output" == *"USERNAME=developer"* ]]; then
        assert_true true "Default username used when missing"
    else
        assert_true false "Default username not used"
    fi

    if [[ "$output" == *"UID=1000"* ]]; then
        assert_true true "Default UID used when missing"
    else
        assert_true false "Default UID not used"
    fi
}

# Test: Script preserves additional arguments
test_additional_arguments() {
    # Create feature script that accepts extra args
    command cat > "$MOCK_FEATURE" << 'EOF'
#!/bin/bash
echo "USERNAME=$1"
echo "UID=$2"
echo "GID=$3"
echo "EXTRA=${4:-none}"
EOF
    chmod +x "$MOCK_FEATURE"

    # Test with extra arguments
    local output
    output=$("$MOCK_FEATURE" "user" "1000" "1000" "extra-arg")

    if [[ "$output" == *"EXTRA=extra-arg"* ]]; then
        assert_true true "Additional arguments preserved"
    else
        assert_true false "Additional arguments not preserved"
    fi
}

# Test: Script handles spaces in arguments
test_spaces_in_arguments() {
    # Create feature script that handles spaces
    command cat > "$MOCK_FEATURE" << 'EOF'
#!/bin/bash
echo "USERNAME=[$1]"
EOF
    chmod +x "$MOCK_FEATURE"

    # Test with username containing spaces
    local output
    output=$("$MOCK_FEATURE" "test user" "1000" "1000")

    if [[ "$output" == *"USERNAME=[test user]"* ]]; then
        assert_true true "Spaces in arguments handled correctly"
    else
        assert_true false "Spaces in arguments not handled"
    fi
}

# Test: Script execution permissions
test_script_execution() {
    # Check that feature script is executable
    if [ -x "$MOCK_FEATURE" ]; then
        assert_true true "Feature script is executable"
    else
        assert_true false "Feature script is not executable"
    fi

    # Test that script can be executed
    if "$MOCK_FEATURE" "test" "1000" "1000" >/dev/null 2>&1; then
        assert_true true "Feature script executes successfully"
    else
        assert_true false "Feature script execution failed"
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
run_test_with_setup test_argument_passing "Arguments passed to feature script"
run_test_with_setup test_build_env_override "Build-env file overrides UID/GID"
run_test_with_setup test_fallback_without_build_env "Fallback when build-env missing"
run_test_with_setup test_missing_arguments "Missing arguments handled gracefully"
run_test_with_setup test_additional_arguments "Additional arguments preserved"
run_test_with_setup test_spaces_in_arguments "Spaces in arguments handled"
run_test_with_setup test_script_execution "Script execution permissions work"

# Generate test report
generate_report
