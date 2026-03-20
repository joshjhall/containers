#!/usr/bin/env bash
# Unit tests for lib/runtime/audit-logger-shippers.sh

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Runtime Audit Logger Shippers Tests"

# ============================================================================
# Test: get_fluentd_config function
# ============================================================================
test_get_fluentd_config_contains_source() {
    unset _AUDIT_LOGGER_SHIPPERS_LOADED
    source "$PROJECT_ROOT/lib/runtime/audit-logger-shippers.sh"

    local output
    output=$(get_fluentd_config)
    assert_contains "$output" "<source>" "Fluentd config contains <source> block"
}

test_get_fluentd_config_contains_audit_path() {
    unset _AUDIT_LOGGER_SHIPPERS_LOADED
    source "$PROJECT_ROOT/lib/runtime/audit-logger-shippers.sh"

    local output
    output=$(get_fluentd_config)
    assert_contains "$output" "/var/log/audit/container-audit.log" "Fluentd config contains audit log path"
}

test_get_fluentd_config_contains_match() {
    unset _AUDIT_LOGGER_SHIPPERS_LOADED
    source "$PROJECT_ROOT/lib/runtime/audit-logger-shippers.sh"

    local output
    output=$(get_fluentd_config)
    assert_contains "$output" "<match container.audit>" "Fluentd config contains match block"
}

# ============================================================================
# Test: get_cloudwatch_config function
# ============================================================================
test_get_cloudwatch_config_is_json() {
    unset _AUDIT_LOGGER_SHIPPERS_LOADED
    source "$PROJECT_ROOT/lib/runtime/audit-logger-shippers.sh"

    local output
    output=$(get_cloudwatch_config)
    assert_contains "$output" "{" "CloudWatch config starts with JSON opening brace"
}

test_get_cloudwatch_config_contains_audit_path() {
    unset _AUDIT_LOGGER_SHIPPERS_LOADED
    source "$PROJECT_ROOT/lib/runtime/audit-logger-shippers.sh"

    local output
    output=$(get_cloudwatch_config)
    assert_contains "$output" "/var/log/audit/container-audit.log" "CloudWatch config contains audit log path"
}

# ============================================================================
# Test: get_loki_config function
# ============================================================================
test_get_loki_config_contains_scrape_configs() {
    unset _AUDIT_LOGGER_SHIPPERS_LOADED
    source "$PROJECT_ROOT/lib/runtime/audit-logger-shippers.sh"

    local output
    output=$(get_loki_config)
    assert_contains "$output" "scrape_configs" "Loki config contains scrape_configs"
}

test_get_loki_config_contains_pipeline_stages() {
    unset _AUDIT_LOGGER_SHIPPERS_LOADED
    source "$PROJECT_ROOT/lib/runtime/audit-logger-shippers.sh"

    local output
    output=$(get_loki_config)
    assert_contains "$output" "pipeline_stages" "Loki config contains pipeline_stages"
}

test_get_loki_config_contains_labels() {
    unset _AUDIT_LOGGER_SHIPPERS_LOADED
    source "$PROJECT_ROOT/lib/runtime/audit-logger-shippers.sh"

    local output
    output=$(get_loki_config)
    assert_contains "$output" "level:" "Loki config contains level label"
    assert_contains "$output" "category:" "Loki config contains category label"
}

# Run tests
run_test test_get_fluentd_config_contains_source "Fluentd config contains source block"
run_test test_get_fluentd_config_contains_audit_path "Fluentd config contains audit log path"
run_test test_get_fluentd_config_contains_match "Fluentd config contains match block"
run_test test_get_cloudwatch_config_is_json "CloudWatch config is JSON"
run_test test_get_cloudwatch_config_contains_audit_path "CloudWatch config contains audit log path"
run_test test_get_loki_config_contains_scrape_configs "Loki config contains scrape_configs"
run_test test_get_loki_config_contains_pipeline_stages "Loki config contains pipeline_stages"
run_test test_get_loki_config_contains_labels "Loki config contains level and category labels"

# Generate test report
generate_report
