#!/usr/bin/env bash
# Unit tests for observability configuration files
#
# Validates that alert rules, dashboard JSON, Prometheus config, and
# docker-compose YAML are syntactically valid. No external services required.

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Source test framework
# shellcheck source=tests/framework.sh
source "$PROJECT_ROOT/tests/framework.sh"

OBSERVABILITY_DIR="$PROJECT_ROOT/examples/observability"

# ============================================================================
# YAML validation helper
# ============================================================================

# Check if a YAML parser is available
YAML_PARSER_AVAILABLE=false
if command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" 2>/dev/null; then
    YAML_PARSER_AVAILABLE=true
    YAML_PYTHON=python3
elif command -v python >/dev/null 2>&1 && python -c "import yaml" 2>/dev/null; then
    YAML_PARSER_AVAILABLE=true
    YAML_PYTHON=python
fi

# Validate YAML syntax using Python's yaml module if available
# Returns 0 on success, 1 on parse error, 2 if no parser available
validate_yaml() {
    local file="$1"
    if [ "$YAML_PARSER_AVAILABLE" = "true" ]; then
        $YAML_PYTHON -c "import yaml, sys; yaml.safe_load(open(sys.argv[1]))" "$file" 2>&1
        return $?
    else
        return 2
    fi
}

# ============================================================================
# Alert rules YAML
# ============================================================================

test_alerts_yaml_exists() {
    start_test "Prometheus alerts.yml exists"

    local alerts_file="$OBSERVABILITY_DIR/prometheus/alerts.yml"
    assert_file_exists "$alerts_file" "alerts.yml should exist"
}

test_alerts_yaml_valid() {
    start_test "Prometheus alerts.yml is valid YAML"

    local alerts_file="$OBSERVABILITY_DIR/prometheus/alerts.yml"
    if [ ! -f "$alerts_file" ]; then
        skip_test "alerts.yml not found"
        return 0
    fi

    local output
    local rc
    output=$(validate_yaml "$alerts_file" 2>&1)
    rc=$?
    if [ "$rc" -eq 2 ]; then
        skip_test "no YAML parser available (python3 + PyYAML required)"
        return 0
    elif [ "$rc" -ne 0 ]; then
        fail_test "alerts.yml is not valid YAML: $output"
        return 1
    fi
    pass_test
}

# ============================================================================
# Prometheus configuration
# ============================================================================

test_prometheus_yml_exists() {
    start_test "prometheus.yml exists"

    local prom_file="$OBSERVABILITY_DIR/prometheus.yml"
    assert_file_exists "$prom_file" "prometheus.yml should exist"
}

test_prometheus_yml_valid() {
    start_test "prometheus.yml is valid YAML"

    local prom_file="$OBSERVABILITY_DIR/prometheus.yml"
    if [ ! -f "$prom_file" ]; then
        skip_test "prometheus.yml not found"
        return 0
    fi

    local output
    local rc
    output=$(validate_yaml "$prom_file" 2>&1)
    rc=$?
    if [ "$rc" -eq 2 ]; then
        skip_test "no YAML parser available (python3 + PyYAML required)"
        return 0
    elif [ "$rc" -ne 0 ]; then
        fail_test "prometheus.yml is not valid YAML: $output"
        return 1
    fi
    pass_test
}

# ============================================================================
# Docker Compose configuration
# ============================================================================

test_docker_compose_yml_exists() {
    start_test "docker-compose.yml exists"

    local compose_file="$OBSERVABILITY_DIR/docker-compose.yml"
    assert_file_exists "$compose_file" "docker-compose.yml should exist"
}

test_docker_compose_yml_valid() {
    start_test "docker-compose.yml is valid YAML"

    local compose_file="$OBSERVABILITY_DIR/docker-compose.yml"
    if [ ! -f "$compose_file" ]; then
        skip_test "docker-compose.yml not found"
        return 0
    fi

    local output
    local rc
    output=$(validate_yaml "$compose_file" 2>&1)
    rc=$?
    if [ "$rc" -eq 2 ]; then
        skip_test "no YAML parser available (python3 + PyYAML required)"
        return 0
    elif [ "$rc" -ne 0 ]; then
        fail_test "docker-compose.yml is not valid YAML: $output"
        return 1
    fi
    pass_test
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

test_grafana_datasources_valid() {
    start_test "grafana-datasources.yml is valid YAML"

    local ds_file="$OBSERVABILITY_DIR/grafana-datasources.yml"
    if [ ! -f "$ds_file" ]; then
        skip_test "grafana-datasources.yml not found"
        return 0
    fi

    local output
    local rc
    output=$(validate_yaml "$ds_file" 2>&1)
    rc=$?
    if [ "$rc" -eq 2 ]; then
        skip_test "no YAML parser available (python3 + PyYAML required)"
        return 0
    elif [ "$rc" -ne 0 ]; then
        fail_test "grafana-datasources.yml is not valid YAML: $output"
        return 1
    fi
    pass_test
}

test_grafana_dashboards_provisioning_valid() {
    start_test "grafana-dashboards.yml is valid YAML"

    local db_file="$OBSERVABILITY_DIR/grafana-dashboards.yml"
    if [ ! -f "$db_file" ]; then
        skip_test "grafana-dashboards.yml not found"
        return 0
    fi

    local output
    local rc
    output=$(validate_yaml "$db_file" 2>&1)
    rc=$?
    if [ "$rc" -eq 2 ]; then
        skip_test "no YAML parser available (python3 + PyYAML required)"
        return 0
    elif [ "$rc" -ne 0 ]; then
        fail_test "grafana-dashboards.yml is not valid YAML: $output"
        return 1
    fi
    pass_test
}

# ============================================================================
# Run all tests
# ============================================================================

run_tests \
    test_alerts_yaml_exists \
    test_alerts_yaml_valid \
    test_prometheus_yml_exists \
    test_prometheus_yml_valid \
    test_docker_compose_yml_exists \
    test_docker_compose_yml_valid \
    test_grafana_dashboards_exist \
    test_build_overview_dashboard_valid_json \
    test_runtime_health_dashboard_valid_json \
    test_grafana_datasources_valid \
    test_grafana_dashboards_provisioning_valid
