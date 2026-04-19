#!/usr/bin/env bash
# Unit tests for observability configuration files
#
# Validates that expected config files exist and JSON files are syntactically
# valid. YAML syntax/style validation is handled by dprint via pre-commit.

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Source test framework
# shellcheck source=tests/framework.sh
source "$PROJECT_ROOT/tests/framework.sh"

OBSERVABILITY_DIR="$PROJECT_ROOT/examples/observability"

# ============================================================================
# Alert rules YAML
# ============================================================================

test_alerts_yaml_exists() {
    start_test "Prometheus alerts.yml exists"

    local alerts_file="$OBSERVABILITY_DIR/prometheus/alerts.yml"
    assert_file_exists "$alerts_file" "alerts.yml should exist"
}

# ============================================================================
# Prometheus configuration
# ============================================================================

test_prometheus_yml_exists() {
    start_test "prometheus.yml exists"

    local prom_file="$OBSERVABILITY_DIR/prometheus.yml"
    assert_file_exists "$prom_file" "prometheus.yml should exist"
}

# ============================================================================
# Docker Compose configuration
# ============================================================================

test_docker_compose_yml_exists() {
    start_test "docker-compose.yml exists"

    local compose_file="$OBSERVABILITY_DIR/docker-compose.yml"
    assert_file_exists "$compose_file" "docker-compose.yml should exist"
}

# ============================================================================
# Grafana dashboard JSON files
# ============================================================================

test_grafana_dashboards_exist() {
    start_test "Grafana dashboard JSON files exist"

    local grafana_dir="$OBSERVABILITY_DIR/grafana"
    assert_file_exists "$grafana_dir/container-build-overview.json" \
        "container-build-overview.json should exist"
    assert_file_exists "$grafana_dir/container-runtime-health.json" \
        "container-runtime-health.json should exist"
}

test_build_overview_dashboard_valid_json() {
    start_test "container-build-overview.json is valid JSON"

    local dashboard="$OBSERVABILITY_DIR/grafana/container-build-overview.json"
    if [ ! -f "$dashboard" ]; then
        skip_test "container-build-overview.json not found"
        return 0
    fi

    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available"
        return 0
    fi

    local output
    output=$(jq '.' "$dashboard" 2>&1 >/dev/null) || {
        fail_test "container-build-overview.json is not valid JSON: $output"
        return 1
    }
    pass_test
}

test_runtime_health_dashboard_valid_json() {
    start_test "container-runtime-health.json is valid JSON"

    local dashboard="$OBSERVABILITY_DIR/grafana/container-runtime-health.json"
    if [ ! -f "$dashboard" ]; then
        skip_test "container-runtime-health.json not found"
        return 0
    fi

    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available"
        return 0
    fi

    local output
    output=$(jq '.' "$dashboard" 2>&1 >/dev/null) || {
        fail_test "container-runtime-health.json is not valid JSON: $output"
        return 1
    }
    pass_test
}

# ============================================================================
# Grafana provisioning YAML
# ============================================================================

test_grafana_datasources_exists() {
    start_test "grafana-datasources.yml exists"

    local ds_file="$OBSERVABILITY_DIR/grafana-datasources.yml"
    assert_file_exists "$ds_file" "grafana-datasources.yml should exist"
}

test_grafana_dashboards_provisioning_exists() {
    start_test "grafana-dashboards.yml exists"

    local db_file="$OBSERVABILITY_DIR/grafana-dashboards.yml"
    assert_file_exists "$db_file" "grafana-dashboards.yml should exist"
}

# ============================================================================
# Run all tests
# ============================================================================

run_tests \
    test_alerts_yaml_exists \
    test_prometheus_yml_exists \
    test_docker_compose_yml_exists \
    test_grafana_dashboards_exist \
    test_build_overview_dashboard_valid_json \
    test_runtime_health_dashboard_valid_json \
    test_grafana_datasources_exists \
    test_grafana_dashboards_provisioning_exists
