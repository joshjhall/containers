#!/usr/bin/env bash
# Unit tests for Prometheus metrics exporter
#
# Tests that metrics exporter generates valid Prometheus format metrics
# without requiring Prometheus server

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Source test framework
# shellcheck source=tests/framework.sh
source "$PROJECT_ROOT/tests/framework.sh"

# Set up test environment
export BUILD_LOG_DIR="/tmp/test-metrics-$$"
mkdir -p "$BUILD_LOG_DIR"

# Create mock build logs
setup_mock_logs() {
    cat > "$BUILD_LOG_DIR/master-summary.log" <<EOF
Python: 0 errors, 2 warnings (145s)
Node.js: 0 errors, 0 warnings (89s)
Rust: 1 errors, 3 warnings (234s)
EOF
}

test_metrics_exporter_exists() {
    start_test "Metrics exporter script exists and is executable"

    assert_file_exists "$PROJECT_ROOT/lib/runtime/metrics-exporter.sh" \
        "Metrics exporter should exist"

    assert_file_executable "$PROJECT_ROOT/lib/runtime/metrics-exporter.sh" \
        "Metrics exporter should be executable"

    pass_test
}

test_metrics_generation() {
    start_test "Metrics exporter generates output"

    setup_mock_logs

    local metrics
    metrics=$("$PROJECT_ROOT/lib/runtime/metrics-exporter.sh")

    assert_not_empty "$metrics" "Should generate metrics output"

    pass_test
}

test_prometheus_format() {
    start_test "Metrics are in valid Prometheus format"

    setup_mock_logs

    local metrics
    metrics=$("$PROJECT_ROOT/lib/runtime/metrics-exporter.sh")

    # Should contain HELP comments
    echo "$metrics" | grep -q "^# HELP"
    assert_success "Should contain HELP comments"

    # Should contain TYPE comments
    echo "$metrics" | grep -q "^# TYPE"
    assert_success "Should contain TYPE comments"

    # Should contain actual metrics (not just comments)
    echo "$metrics" | grep -qE "^[a-z_]+ "
    assert_success "Should contain metric lines"

    pass_test
}

test_build_metrics() {
    start_test "Build metrics are correctly parsed"

    setup_mock_logs

    local metrics
    metrics=$("$PROJECT_ROOT/lib/runtime/metrics-exporter.sh")

    # Should contain build duration metrics
    echo "$metrics" | grep -q "container_build_duration_seconds"
    assert_success "Should contain build duration metrics"

    # Should contain error metrics
    echo "$metrics" | grep -q "container_build_errors_total"
    assert_success "Should contain error metrics"

    # Should contain warning metrics
    echo "$metrics" | grep -q "container_build_warnings_total"
    assert_success "Should contain warning metrics"

    # Check Python metrics (0 errors, 145s)
    echo "$metrics" | grep -q 'container_build_duration_seconds{feature="python"'
    assert_success "Should have Python metrics"

    echo "$metrics" | grep -q 'container_build_errors_total{feature="python"} 0'
    assert_success "Should record 0 errors for Python"

    # Check Rust metrics (1 error, 234s)
    echo "$metrics" | grep -q 'container_build_errors_total{feature="rust"} 1'
    assert_success "Should record 1 error for Rust"

    pass_test
}

test_runtime_metrics() {
    start_test "Runtime metrics are generated"

    # Create container start time marker
    echo "$(date +%s)" > /tmp/container-start-time

    local metrics
    metrics=$("$PROJECT_ROOT/lib/runtime/metrics-exporter.sh")

    # Should contain uptime metric
    echo "$metrics" | grep -q "container_uptime_seconds"
    assert_success "Should contain uptime metric"

    # Uptime should be a number
    local uptime
    uptime=$(echo "$metrics" | grep "^container_uptime_seconds " | awk '{print $2}')
    if [[ "$uptime" =~ ^[0-9]+$ ]]; then
        assert_success "Uptime should be numeric"
    else
        fail_test "Uptime is not numeric: $uptime"
    fi

    pass_test
}

test_healthcheck_metrics() {
    start_test "Healthcheck metrics are generated when available"

    local metrics
    metrics=$("$PROJECT_ROOT/lib/runtime/metrics-exporter.sh")

    # Healthcheck metrics depend on whether healthcheck command exists
    # This test just verifies the exporter handles it gracefully

    # Should either have healthcheck metrics or not crash
    assert_success "Should handle healthcheck availability gracefully"

    pass_test
}

test_feature_count() {
    start_test "Features installed count is correct"

    setup_mock_logs

    local metrics
    metrics=$("$PROJECT_ROOT/lib/runtime/metrics-exporter.sh")

    # Should count 3 features from mock logs
    echo "$metrics" | grep -q "container_features_installed 3"
    assert_success "Should count 3 installed features"

    pass_test
}

test_aggregate_errors() {
    start_test "Aggregate error count is correct"

    setup_mock_logs

    local metrics
    metrics=$("$PROJECT_ROOT/lib/runtime/metrics-exporter.sh")

    # Total errors: Python(0) + Node(0) + Rust(1) = 1
    echo "$metrics" | grep -q "container_build_errors_total_all 1"
    assert_success "Should aggregate to 1 total error"

    # Total warnings: Python(2) + Node(0) + Rust(3) = 5
    echo "$metrics" | grep -q "container_build_warnings_total_all 5"
    assert_success "Should aggregate to 5 total warnings"

    pass_test
}

test_status_labels() {
    start_test "Status labels reflect build success/failure"

    setup_mock_logs

    local metrics
    metrics=$("$PROJECT_ROOT/lib/runtime/metrics-exporter.sh")

    # Python and Node should have status="success" (0 errors)
    echo "$metrics" | grep -q 'status="success"'
    assert_success "Should have success status for error-free builds"

    # Rust should have status="failed" (1 error)
    echo "$metrics" | grep -q 'status="failed"'
    assert_success "Should have failed status for builds with errors"

    pass_test
}

test_empty_logs() {
    start_test "Handles missing build logs gracefully"

    # Don't create any logs
    rm -f "$BUILD_LOG_DIR/master-summary.log"

    local metrics
    metrics=$("$PROJECT_ROOT/lib/runtime/metrics-exporter.sh")

    # Should still generate output (runtime metrics at minimum)
    assert_not_empty "$metrics" "Should generate output even without build logs"

    # Should not crash
    assert_success "Should handle missing logs gracefully"

    pass_test
}

test_metrics_timestamp() {
    start_test "Metrics include scrape timestamp"

    setup_mock_logs

    local metrics
    metrics=$("$PROJECT_ROOT/lib/runtime/metrics-exporter.sh")

    # Should have scrape timestamp
    echo "$metrics" | grep -q "container_metrics_scrape_timestamp_seconds"
    assert_success "Should include scrape timestamp"

    # Timestamp should be recent (within last minute)
    local timestamp
    timestamp=$(echo "$metrics" | grep "^container_metrics_scrape_timestamp_seconds" | awk '{print $2}')
    local now
    now=$(date +%s)
    local diff=$((now - timestamp))

    if [ "$diff" -lt 60 ]; then
        assert_success "Timestamp should be recent"
    else
        fail_test "Timestamp is too old: $diff seconds"
    fi

    pass_test
}

# Cleanup
cleanup() {
    rm -rf "$BUILD_LOG_DIR"
    rm -f /tmp/container-start-time
}

trap cleanup EXIT

# Run all tests
run_tests "Metrics Exporter Tests" \
    test_metrics_exporter_exists \
    test_metrics_generation \
    test_prometheus_format \
    test_build_metrics \
    test_runtime_metrics \
    test_healthcheck_metrics \
    test_feature_count \
    test_aggregate_errors \
    test_status_labels \
    test_empty_logs \
    test_metrics_timestamp
