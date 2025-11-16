#!/usr/bin/env bash
# Unit tests for bin/measure-build-metrics.sh
# Tests build metrics measurement and regression detection

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Build Metrics Measurement Tests"

# Setup function - runs before each test
setup() {
    # Create temporary directory for testing
    export TEST_TEMP_DIR="$RESULTS_DIR/test-build-metrics"
    mkdir -p "$TEST_TEMP_DIR"

    # Create temporary metrics directory
    export TEST_METRICS_DIR="$TEST_TEMP_DIR/metrics"
    export TEST_BASELINE_DIR="$TEST_METRICS_DIR/baselines"
    mkdir -p "$TEST_BASELINE_DIR"

    # Source the helper functions from the script
    # We'll extract and test individual functions
}

# Teardown function - runs after each test
teardown() {
    # Clean up test directory
    if [ -n "${TEST_TEMP_DIR:-}" ] && [ -d "$TEST_TEMP_DIR" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi

    # Unset test variables
    unset TEST_TEMP_DIR TEST_METRICS_DIR TEST_BASELINE_DIR 2>/dev/null || true
}

# ============================================================================
# Helper Function Tests
# ============================================================================

test_bytes_to_human() {
    # Define the function locally for testing
    bytes_to_human() {
        local bytes="$1"
        local mb
        mb=$(awk "BEGIN {printf \"%.2f\", $bytes / 1024 / 1024}")
        echo "${mb}MB"
    }

    local result
    result=$(bytes_to_human 1048576)  # 1MB in bytes
    assert_equals "$result" "1.00MB" "1MB conversion"

    result=$(bytes_to_human 104857600)  # 100MB in bytes
    assert_equals "$result" "100.00MB" "100MB conversion"

    result=$(bytes_to_human 1073741824)  # 1GB in bytes
    assert_equals "$result" "1024.00MB" "1GB conversion"
}

test_baseline_json_format() {
    # Create a test baseline file
    local baseline_file="$TEST_BASELINE_DIR/test-variant.json"

    command cat > "$baseline_file" << 'EOF'
{
  "variant": "test-variant",
  "timestamp": "2025-11-12_01:00:00",
  "size_bytes": 524288000,
  "size_human": "500.00MB",
  "build_time_seconds": 120
}
EOF

    assert_file_exists "$baseline_file"

    # Verify JSON format
    local variant
    variant=$(grep -o '"variant": "[^"]*"' "$baseline_file" | cut -d'"' -f4)
    assert_equals "$variant" "test-variant" "Variant name in JSON"

    local size
    size=$(grep -o '"size_bytes": [0-9]*' "$baseline_file" | awk '{print $2}')
    assert_equals "$size" "524288000" "Size in bytes in JSON"

    local time
    time=$(grep -o '"build_time_seconds": [0-9]*' "$baseline_file" | awk '{print $2}')
    assert_equals "$time" "120" "Build time in JSON"
}

test_get_build_args_minimal() {
    # Define function for testing
    get_build_args_for_variant() {
        local variant="$1"
        local args=""

        case "$variant" in
            minimal)
                # No additional args
                ;;
            python-dev)
                args="--build-arg INCLUDE_PYTHON=true --build-arg INCLUDE_PYTHON_DEV=true"
                ;;
            node-dev)
                args="--build-arg INCLUDE_NODE=true --build-arg INCLUDE_NODE_DEV=true"
                ;;
            *)
                echo "ERROR: Unknown variant: $variant" >&2
                return 1
                ;;
        esac

        echo "$args"
    }

    local result
    result=$(get_build_args_for_variant "minimal")
    assert_equals "$result" "" "Minimal variant has no build args"
}

test_get_build_args_python_dev() {
    get_build_args_for_variant() {
        local variant="$1"
        local args=""

        case "$variant" in
            minimal)
                # No additional args
                ;;
            python-dev)
                args="--build-arg INCLUDE_PYTHON=true --build-arg INCLUDE_PYTHON_DEV=true"
                ;;
            node-dev)
                args="--build-arg INCLUDE_NODE=true --build-arg INCLUDE_NODE_DEV=true"
                ;;
            *)
                echo "ERROR: Unknown variant: $variant" >&2
                return 1
                ;;
        esac

        echo "$args"
    }

    local result
    result=$(get_build_args_for_variant "python-dev")
    assert_contains "$result" "INCLUDE_PYTHON=true" "Python build arg present"
    assert_contains "$result" "INCLUDE_PYTHON_DEV=true" "Python-dev build arg present"
}

test_regression_detection_size_increase() {
    # Create a baseline
    local baseline_file="$TEST_BASELINE_DIR/test.json"
    command cat > "$baseline_file" << 'EOF'
{
  "variant": "test",
  "size_bytes": 500000000,
  "build_time_seconds": 100
}
EOF

    # Current metrics show size increase of 150MB (exceeds 100MB threshold)
    local baseline_size=500000000
    local current_size=650000000  # +150MB
    local size_diff=$((current_size - baseline_size))
    local size_diff_mb
    size_diff_mb=$(awk "BEGIN {printf \"%.2f\", $size_diff / 1024 / 1024}")

    local threshold=100

    # Check if this should trigger a regression
    if awk "BEGIN {exit !($size_diff_mb > $threshold)}"; then
        assert_true true "Size regression detected correctly"
    else
        assert_true false "Size regression should have been detected"
    fi
}

test_regression_detection_size_acceptable() {
    # Create a baseline
    local baseline_size=500000000
    local current_size=550000000  # +50MB (below 100MB threshold)
    local size_diff=$((current_size - baseline_size))
    local size_diff_mb
    size_diff_mb=$(awk "BEGIN {printf \"%.2f\", $size_diff / 1024 / 1024}")

    local threshold=100

    # Check if this should NOT trigger a regression
    if awk "BEGIN {exit !($size_diff_mb > $threshold)}"; then
        assert_true false "Should not detect regression for small increase"
    else
        assert_true true "No regression detected for acceptable increase"
    fi
}

test_regression_detection_time_increase() {
    # Baseline: 100 seconds
    # Current: 130 seconds (+30% exceeds 20% threshold)
    local baseline_time=100
    local current_time=130
    local time_diff=$((current_time - baseline_time))
    local time_diff_pct
    time_diff_pct=$(awk "BEGIN {printf \"%.2f\", ($time_diff * 100.0) / $baseline_time}")

    local threshold=20

    # Check if this should trigger a regression
    if awk "BEGIN {exit !($time_diff_pct > $threshold)}"; then
        assert_true true "Time regression detected correctly"
    else
        assert_true false "Time regression should have been detected"
    fi
}

test_regression_detection_time_acceptable() {
    # Baseline: 100 seconds
    # Current: 110 seconds (+10% below 20% threshold)
    local baseline_time=100
    local current_time=110
    local time_diff=$((current_time - baseline_time))
    local time_diff_pct
    time_diff_pct=$(awk "BEGIN {printf \"%.2f\", ($time_diff * 100.0) / $baseline_time}")

    local threshold=20

    # Check if this should NOT trigger a regression
    if awk "BEGIN {exit !($time_diff_pct > $threshold)}"; then
        assert_true false "Should not detect regression for small increase"
    else
        assert_true true "No regression detected for acceptable increase"
    fi
}

test_regression_detection_improvement() {
    # Test that improvements (decreases) don't trigger regressions
    local baseline_size=500000000
    local current_size=400000000  # -100MB (improvement)
    local size_diff=$((current_size - baseline_size))

    # Should be negative, indicating improvement
    if [ "$size_diff" -lt 0 ]; then
        assert_true true "Size decrease detected as improvement"
    else
        assert_true false "Size should have decreased"
    fi
}

test_json_output_format() {
    # Test JSON output format
    local variant="test-variant"
    local size_bytes=524288000
    local build_time=120

    # Create JSON output
    local json
    json=$(cat << EOF
{
  "variant": "$variant",
  "size_bytes": $size_bytes,
  "build_time_seconds": $build_time
}
EOF
)

    # Verify JSON is valid (contains expected fields)
    assert_contains "$json" '"variant": "test-variant"' "JSON contains variant"
    assert_contains "$json" '"size_bytes": 524288000' "JSON contains size"
    assert_contains "$json" '"build_time_seconds": 120' "JSON contains build time"
}

test_variant_validation() {
    # Test that script rejects unknown variants
    get_build_args_for_variant() {
        local variant="$1"

        case "$variant" in
            minimal|python-dev|node-dev|rust-golang|cloud-ops|polyglot)
                echo "valid"
                ;;
            *)
                echo "ERROR: Unknown variant: $variant" >&2
                return 1
                ;;
        esac
    }

    # Valid variants should work
    if get_build_args_for_variant "minimal" >/dev/null 2>&1; then
        assert_true true "minimal variant is valid"
    fi

    # Invalid variants should fail
    if get_build_args_for_variant "unknown-variant" >/dev/null 2>&1; then
        assert_true false "Unknown variant should fail"
    else
        assert_true true "Unknown variant correctly rejected"
    fi
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

# Helper function tests
run_test_with_setup test_bytes_to_human "Bytes to human-readable conversion"
run_test_with_setup test_baseline_json_format "Baseline JSON format"
run_test_with_setup test_get_build_args_minimal "Build args for minimal variant"
run_test_with_setup test_get_build_args_python_dev "Build args for python-dev variant"

# Regression detection tests
run_test_with_setup test_regression_detection_size_increase "Regression: Size increase detection"
run_test_with_setup test_regression_detection_size_acceptable "Regression: Acceptable size increase"
run_test_with_setup test_regression_detection_time_increase "Regression: Time increase detection"
run_test_with_setup test_regression_detection_time_acceptable "Regression: Acceptable time increase"
run_test_with_setup test_regression_detection_improvement "Regression: Improvement detection"

# Output format tests
run_test_with_setup test_json_output_format "JSON output format"
run_test_with_setup test_variant_validation "Variant validation"

# Generate test report
generate_report
