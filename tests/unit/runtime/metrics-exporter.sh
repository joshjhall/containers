#!/usr/bin/env bash
# Unit tests for lib/runtime/metrics-exporter.sh
# Tests Prometheus metrics exporter functionality

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Metrics Exporter Tests"

# Path to script under test
SOURCE_FILE="$PROJECT_ROOT/lib/runtime/metrics-exporter.sh"

# Setup function - runs before each test
setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$RESULTS_DIR/test-metrics-exporter-$unique_id"
    mkdir -p "$TEST_TEMP_DIR"
}

# Teardown function - runs after each test
teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
}

# ============================================================================
# Static Analysis Tests
# ============================================================================

# Test: Script has set -euo pipefail
test_strict_mode() {
    assert_file_contains "$SOURCE_FILE" "set -euo pipefail" \
        "Script should use strict mode (set -euo pipefail)"
}

# Test: Defines collect_build_metrics function
test_defines_collect_build_metrics() {
    assert_file_contains "$SOURCE_FILE" "collect_build_metrics()" \
        "Script should define collect_build_metrics function"
}

# Test: Defines collect_runtime_metrics function
test_defines_collect_runtime_metrics() {
    assert_file_contains "$SOURCE_FILE" "collect_runtime_metrics()" \
        "Script should define collect_runtime_metrics function"
}

# Test: Defines collect_json_metrics function
test_defines_collect_json_metrics() {
    assert_file_contains "$SOURCE_FILE" "collect_json_metrics()" \
        "Script should define collect_json_metrics function"
}

# Test: Defines generate_metrics function
test_defines_generate_metrics() {
    assert_file_contains "$SOURCE_FILE" "generate_metrics()" \
        "Script should define generate_metrics function"
}

# Test: Defines serve_http function
test_defines_serve_http() {
    assert_file_contains "$SOURCE_FILE" "serve_http()" \
        "Script should define serve_http function"
}

# Test: Defines serve_file function
test_defines_serve_file() {
    assert_file_contains "$SOURCE_FILE" "serve_file()" \
        "Script should define serve_file function"
}

# Test: Defines main function
test_defines_main() {
    assert_file_contains "$SOURCE_FILE" "main()" \
        "Script should define main function"
}

# Test: METRICS_PORT defaults to 9090
test_metrics_port_default() {
    assert_file_contains "$SOURCE_FILE" 'METRICS_PORT:-9090' \
        "METRICS_PORT should default to 9090"
}

# Test: METRICS_REFRESH_INTERVAL defaults to 15
test_metrics_refresh_interval_default() {
    assert_file_contains "$SOURCE_FILE" 'METRICS_REFRESH_INTERVAL:-15' \
        "METRICS_REFRESH_INTERVAL should default to 15"
}

# Test: Prometheus format markers (# TYPE, # HELP)
test_prometheus_format_markers() {
    assert_file_contains "$SOURCE_FILE" "# TYPE" \
        "Script should contain Prometheus TYPE markers"
    assert_file_contains "$SOURCE_FILE" "# HELP" \
        "Script should contain Prometheus HELP markers"
}

# Test: container_build_duration_seconds metric name
test_build_duration_metric() {
    assert_file_contains "$SOURCE_FILE" "container_build_duration_seconds" \
        "Script should define container_build_duration_seconds metric"
}

# Test: container_uptime_seconds metric name
test_uptime_metric() {
    assert_file_contains "$SOURCE_FILE" "container_uptime_seconds" \
        "Script should define container_uptime_seconds metric"
}

# Test: container_features_installed metric name
test_features_installed_metric() {
    assert_file_contains "$SOURCE_FILE" "container_features_installed" \
        "Script should define container_features_installed metric"
}

# Test: container_metrics_scrape_timestamp_seconds metric
test_scrape_timestamp_metric() {
    assert_file_contains "$SOURCE_FILE" "container_metrics_scrape_timestamp_seconds" \
        "Script should define container_metrics_scrape_timestamp_seconds metric"
}

# Test: BASH_SOURCE guard for direct execution
test_bash_source_guard() {
    assert_file_contains "$SOURCE_FILE" 'BASH_SOURCE\[0\].*\$0' \
        "Script should check BASH_SOURCE[0] for direct execution guard"
}

# Test: --help flag handling
test_help_flag_handling() {
    assert_file_contains "$SOURCE_FILE" "\-\-help" \
        "Script should handle --help flag"
}

# Test: socat and nc as HTTP server options
test_http_server_options() {
    assert_file_contains "$SOURCE_FILE" "socat" \
        "Script should support socat as HTTP server"
    assert_file_contains "$SOURCE_FILE" "nc" \
        "Script should support nc (netcat) as HTTP server"
}

# ============================================================================
# Run tests
# ============================================================================

run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"

    setup
    run_test "$test_function" "$test_description"
    teardown
}

# Static analysis tests
run_test test_strict_mode "Script has set -euo pipefail"
run_test test_defines_collect_build_metrics "Defines collect_build_metrics function"
run_test test_defines_collect_runtime_metrics "Defines collect_runtime_metrics function"
run_test test_defines_collect_json_metrics "Defines collect_json_metrics function"
run_test test_defines_generate_metrics "Defines generate_metrics function"
run_test test_defines_serve_http "Defines serve_http function"
run_test test_defines_serve_file "Defines serve_file function"
run_test test_defines_main "Defines main function"
run_test test_metrics_port_default "METRICS_PORT defaults to 9090"
run_test test_metrics_refresh_interval_default "METRICS_REFRESH_INTERVAL defaults to 15"
run_test test_prometheus_format_markers "Prometheus format markers present"
run_test test_build_duration_metric "container_build_duration_seconds metric defined"
run_test test_uptime_metric "container_uptime_seconds metric defined"
run_test test_features_installed_metric "container_features_installed metric defined"
run_test test_scrape_timestamp_metric "container_metrics_scrape_timestamp_seconds metric defined"
run_test test_bash_source_guard "BASH_SOURCE guard for direct execution"
run_test test_help_flag_handling "--help flag handling"
run_test test_http_server_options "socat and nc as HTTP server options"

# Generate test report
generate_report
