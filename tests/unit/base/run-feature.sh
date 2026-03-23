#!/usr/bin/env bash
# Unit tests for lib/base/run-feature.sh
# Tests the feature script wrapper by running a modified copy of the real script.

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Run Feature Wrapper Tests"

# Path to the source script under test
SOURCE_SCRIPT="$PROJECT_ROOT/lib/base/run-feature.sh"

# Setup function - runs before each test
setup() {
    local unique_id
    unique_id="$$-$(date +%s%N 2>/dev/null || date +%s)"
    export TEST_TEMP_DIR="$RESULTS_DIR/test-run-feature-$unique_id"
    mkdir -p "$TEST_TEMP_DIR"

    # Create a modified copy of the real script that:
    #   1. Replaces /tmp/build-env with $TEST_TEMP_DIR/build-env so tests
    #      never touch the real /tmp/build-env
    #   2. Replaces `exec` with plain invocation so the test process is not
    #      replaced and we can capture output
    export WRAPPER_SCRIPT="$TEST_TEMP_DIR/run-feature-testable.sh"
    command sed \
        -e "s|/tmp/build-env|\$TEST_TEMP_DIR/build-env|g" \
        -e "s|exec \"\$FEATURE_SCRIPT\"|\"\$FEATURE_SCRIPT\"|g" \
        "$SOURCE_SCRIPT" > "$WRAPPER_SCRIPT"
    chmod +x "$WRAPPER_SCRIPT"

    # Create the standard mock feature script that prints its received args
    export MOCK_FEATURE="$TEST_TEMP_DIR/feature.sh"
    command cat > "$MOCK_FEATURE" << 'EOF'
#!/bin/bash
echo "ARG1=${1:-<unset>}"
echo "ARG2=${2:-<unset>}"
echo "ARG3=${3:-<unset>}"
echo "ARGC=$#"
EOF
    chmod +x "$MOCK_FEATURE"
}

# Teardown function - runs after each test
teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
    unset WRAPPER_SCRIPT MOCK_FEATURE 2>/dev/null || true
}

# ============================================================================
# Static / filesystem tests
# ============================================================================

# Test 1: Source script exists and is executable
test_source_script_exists_and_is_executable() {
    if [ ! -f "$SOURCE_SCRIPT" ]; then
        assert_true false "Source script $SOURCE_SCRIPT not found"
        return
    fi
    assert_true true "Source script exists"

    if [ ! -x "$SOURCE_SCRIPT" ]; then
        assert_true false "Source script $SOURCE_SCRIPT is not executable"
        return
    fi
    assert_true true "Source script is executable"
}

# ============================================================================
# With build-env present
# ============================================================================

# Test 2: ACTUAL_UID and ACTUAL_GID from build-env override the passed-in args
test_build_env_uid_gid_override_passed_args() {
    command cat > "$TEST_TEMP_DIR/build-env" << 'EOF'
ACTUAL_UID=2000
ACTUAL_GID=3000
EOF

    local output
    output=$(TEST_TEMP_DIR="$TEST_TEMP_DIR" bash "$WRAPPER_SCRIPT" \
        "$MOCK_FEATURE" "testuser" "1000" "1001")

    assert_contains "$output" "ARG2=2000" "ACTUAL_UID from build-env overrides passed UID"
    assert_contains "$output" "ARG3=3000" "ACTUAL_GID from build-env overrides passed GID"
}

# Test 3: USERNAME from positional arg is passed through to the feature script
test_build_env_username_passed_through() {
    command cat > "$TEST_TEMP_DIR/build-env" << 'EOF'
ACTUAL_UID=500
ACTUAL_GID=500
EOF

    local output
    output=$(TEST_TEMP_DIR="$TEST_TEMP_DIR" bash "$WRAPPER_SCRIPT" \
        "$MOCK_FEATURE" "myuser" "1000" "1001")

    assert_contains "$output" "ARG1=myuser" "Username from positional arg is passed to feature script"
}

# Test 4: Default USERNAME is "developer" when no positional arg given after shift
test_build_env_default_username_is_developer() {
    command cat > "$TEST_TEMP_DIR/build-env" << 'EOF'
ACTUAL_UID=500
ACTUAL_GID=500
EOF

    # After the wrapper shifts $1 (the feature script), there are no remaining
    # args, so USERNAME should default to "developer"
    local output
    output=$(TEST_TEMP_DIR="$TEST_TEMP_DIR" bash "$WRAPPER_SCRIPT" "$MOCK_FEATURE")

    assert_contains "$output" "ARG1=developer" "Default USERNAME is developer when no arg provided"
}

# ============================================================================
# Without build-env
# ============================================================================

# Test 5: All args pass through unchanged when build-env is absent
test_no_build_env_all_args_pass_through() {
    # Ensure no build-env exists
    command rm -f "$TEST_TEMP_DIR/build-env"

    local output
    output=$(TEST_TEMP_DIR="$TEST_TEMP_DIR" bash "$WRAPPER_SCRIPT" \
        "$MOCK_FEATURE" "alice" "4000" "5000")

    assert_contains "$output" "ARG1=alice" "Username passed through without build-env"
    assert_contains "$output" "ARG2=4000" "UID passed through without build-env"
    assert_contains "$output" "ARG3=5000" "GID passed through without build-env"
}

# Test 6: Feature script receives the correct argument count without build-env
test_no_build_env_correct_arg_count() {
    command rm -f "$TEST_TEMP_DIR/build-env"

    local output
    output=$(TEST_TEMP_DIR="$TEST_TEMP_DIR" bash "$WRAPPER_SCRIPT" \
        "$MOCK_FEATURE" "bob" "100" "200")

    assert_contains "$output" "ARGC=3" "Feature script receives exactly 3 args without build-env"
}

# ============================================================================
# Edge cases
# ============================================================================

# Test 7: build-env with only ACTUAL_UID set — GID falls back to the passed value
test_build_env_only_actual_uid_gid_falls_back() {
    # build-env has ACTUAL_UID but no ACTUAL_GID
    command cat > "$TEST_TEMP_DIR/build-env" << 'EOF'
ACTUAL_UID=7777
EOF

    local output
    output=$(TEST_TEMP_DIR="$TEST_TEMP_DIR" bash "$WRAPPER_SCRIPT" \
        "$MOCK_FEATURE" "carol" "1000" "9999")

    assert_contains "$output" "ARG2=7777" "ACTUAL_UID from build-env is used"
    assert_contains "$output" "ARG3=9999" "GID falls back to passed value when ACTUAL_GID absent"
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

run_test_with_setup test_source_script_exists_and_is_executable \
    "Source script exists and is executable"

run_test_with_setup test_build_env_uid_gid_override_passed_args \
    "build-env ACTUAL_UID/ACTUAL_GID override passed-in args"

run_test_with_setup test_build_env_username_passed_through \
    "build-env present: USERNAME positional arg passed through"

run_test_with_setup test_build_env_default_username_is_developer \
    "build-env present: default USERNAME is developer when omitted"

run_test_with_setup test_no_build_env_all_args_pass_through \
    "no build-env: all args pass through unchanged"

run_test_with_setup test_no_build_env_correct_arg_count \
    "no build-env: feature script receives correct arg count"

run_test_with_setup test_build_env_only_actual_uid_gid_falls_back \
    "build-env with only ACTUAL_UID: GID falls back to passed value"

# Generate test report
generate_report
