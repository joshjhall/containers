#!/usr/bin/env bash
# Prometheus metrics exporter for container observability
#
# This script exposes container build and runtime metrics in Prometheus format.
# It can run as an HTTP endpoint or write metrics to a file for collection.
#
# Usage:
#   # Start HTTP server (requires socat or nc)
#   metrics-exporter.sh --server --port 9090
#
#   # Write metrics to file
#   metrics-exporter.sh --file /var/metrics/prometheus.txt
#
#   # Print metrics to stdout (for testing)
#   metrics-exporter.sh
#
# Environment Variables:
#   METRICS_PORT=9090              Port for HTTP server (default: 9090)
#   METRICS_REFRESH_INTERVAL=15    How often to refresh metrics in seconds (default: 15)
#   BUILD_LOG_DIR                  Directory containing build logs

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

METRICS_PORT="${METRICS_PORT:-9090}"
METRICS_REFRESH_INTERVAL="${METRICS_REFRESH_INTERVAL:-15}"
BUILD_LOG_DIR="${BUILD_LOG_DIR:-/var/log/container-build}"
METRICS_FILE="${METRICS_FILE:-}"

# Container start time (for uptime calculation)
if [ ! -f /tmp/container-start-time ]; then
    date +%s > /tmp/container-start-time
fi
CONTAINER_START_TIME=$(cat /tmp/container-start-time)

# ============================================================================
# collect_build_metrics - Extract metrics from build logs
# ============================================================================
collect_build_metrics() {
    local metrics=""

    # Check if build log directory exists
    if [ ! -d "$BUILD_LOG_DIR" ]; then
        return 0
    fi

    # Parse master summary log if it exists
    if [ -f "$BUILD_LOG_DIR/master-summary.log" ]; then
        local feature_count=0
        local total_errors=0
        local total_warnings=0

        while IFS= read -r line; do
            # Format: "Feature: N errors, M warnings (Xs)"
            if [[ "$line" =~ ^([^:]+):[[:space:]]([0-9]+)[[:space:]]errors,[[:space:]]([0-9]+)[[:space:]]warnings[[:space:]]\(([0-9.]+)s\) ]]; then
                local feature="${BASH_REMATCH[1]}"
                local errors="${BASH_REMATCH[2]}"
                local warnings="${BASH_REMATCH[3]}"
                local duration="${BASH_REMATCH[4]}"

                # Sanitize feature name for Prometheus label
                feature=$(echo "$feature" | tr ' ' '_' | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]_-')

                # Build duration metric
                metrics+="# HELP container_build_duration_seconds Time taken to build container feature\n"
                metrics+="# TYPE container_build_duration_seconds gauge\n"
                metrics+="container_build_duration_seconds{feature=\"${feature}\",status=\"$([ "$errors" -eq 0 ] && echo 'success' || echo 'failed')\"} ${duration}\n"

                # Build errors metric
                metrics+="# HELP container_build_errors_total Total errors during container build\n"
                metrics+="# TYPE container_build_errors_total counter\n"
                metrics+="container_build_errors_total{feature=\"${feature}\"} ${errors}\n"

                # Build warnings metric
                metrics+="# HELP container_build_warnings_total Total warnings during container build\n"
                metrics+="# TYPE container_build_warnings_total counter\n"
                metrics+="container_build_warnings_total{feature=\"${feature}\"} ${warnings}\n"

                feature_count=$((feature_count + 1))
                total_errors=$((total_errors + errors))
                total_warnings=$((total_warnings + warnings))
            fi
        done < "$BUILD_LOG_DIR/master-summary.log"

        # Total features installed
        metrics+="# HELP container_features_installed Total number of features installed\n"
        metrics+="# TYPE container_features_installed gauge\n"
        metrics+="container_features_installed ${feature_count}\n"

        # Total build errors across all features
        metrics+="# HELP container_build_errors_total_all Total errors across all features\n"
        metrics+="# TYPE container_build_errors_total_all counter\n"
        metrics+="container_build_errors_total_all ${total_errors}\n"

        # Total build warnings across all features
        metrics+="# HELP container_build_warnings_total_all Total warnings across all features\n"
        metrics+="# TYPE container_build_warnings_total_all counter\n"
        metrics+="container_build_warnings_total_all ${total_warnings}\n"
    fi

    echo -e "$metrics"
}

# ============================================================================
# collect_runtime_metrics - Collect current runtime metrics
# ============================================================================
collect_runtime_metrics() {
    local metrics=""

    # Container uptime
    local current_time
    current_time=$(date +%s)
    local uptime=$((current_time - CONTAINER_START_TIME))

    metrics+="# HELP container_uptime_seconds Container uptime in seconds\n"
    metrics+="# TYPE container_uptime_seconds gauge\n"
    metrics+="container_uptime_seconds ${uptime}\n"

    # Healthcheck status (if healthcheck command exists)
    if command -v healthcheck >/dev/null 2>&1; then
        local health_start
        health_start=$(date +%s%3N 2>/dev/null || date +%s)

        local health_status=1
        if ! healthcheck --quick >/dev/null 2>&1; then
            health_status=0
        fi

        local health_end
        health_end=$(date +%s%3N 2>/dev/null || date +%s)
        local health_duration
        health_duration=$(echo "scale=3; ($health_end - $health_start) / 1000" | bc 2>/dev/null || echo "0")

        metrics+="# HELP container_healthcheck_status Current health status (1=healthy, 0=unhealthy)\n"
        metrics+="# TYPE container_healthcheck_status gauge\n"
        metrics+="container_healthcheck_status ${health_status}\n"

        metrics+="# HELP container_healthcheck_duration_seconds Time taken for last healthcheck\n"
        metrics+="# TYPE container_healthcheck_duration_seconds gauge\n"
        metrics+="container_healthcheck_duration_seconds ${health_duration}\n"
    fi

    # Disk usage metrics (if df available)
    if command -v df >/dev/null 2>&1; then
        # Cache directory
        if [ -d "/cache" ]; then
            local cache_bytes
            cache_bytes=$(du -sb /cache 2>/dev/null | awk '{print $1}' || echo "0")
            metrics+="# HELP container_disk_usage_bytes Disk space used by container directories\n"
            metrics+="# TYPE container_disk_usage_bytes gauge\n"
            metrics+="container_disk_usage_bytes{path=\"/cache\"} ${cache_bytes}\n"
        fi

        # Workspace directory
        if [ -d "/workspace" ]; then
            local workspace_bytes
            workspace_bytes=$(du -sb /workspace 2>/dev/null | awk '{print $1}' || echo "0")
            metrics+="container_disk_usage_bytes{path=\"/workspace\"} ${workspace_bytes}\n"
        fi

        # Log directory
        if [ -d "$BUILD_LOG_DIR" ]; then
            local logs_bytes
            logs_bytes=$(du -sb "$BUILD_LOG_DIR" 2>/dev/null | awk '{print $1}' || echo "0")
            metrics+="container_disk_usage_bytes{path=\"${BUILD_LOG_DIR}\"} ${logs_bytes}\n"
        fi
    fi

    echo -e "$metrics"
}

# ============================================================================
# collect_json_metrics - Extract metrics from JSON logs (if available)
# ============================================================================
collect_json_metrics() {
    local metrics=""
    local json_summary="$BUILD_LOG_DIR/json/build-summary.jsonl"

    if [ ! -f "$json_summary" ]; then
        return 0
    fi

    # If jq is available, use it for better JSON parsing
    if command -v jq >/dev/null 2>&1; then
        while IFS= read -r entry; do
            local feature
            local duration
            local errors
            local warnings
            local status

            feature=$(echo "$entry" | jq -r '.feature // "unknown"' 2>/dev/null || echo "unknown")
            duration=$(echo "$entry" | jq -r '.duration_seconds // 0' 2>/dev/null || echo "0")
            errors=$(echo "$entry" | jq -r '.errors // 0' 2>/dev/null || echo "0")
            warnings=$(echo "$entry" | jq -r '.warnings // 0' 2>/dev/null || echo "0")
            status=$(echo "$entry" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")

            # Sanitize feature name
            feature=$(echo "$feature" | tr ' ' '_' | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]_-')

            # Add metric with json_source label to distinguish from text logs
            metrics+="# HELP container_build_json_duration_seconds Build duration from JSON logs\n"
            metrics+="# TYPE container_build_json_duration_seconds gauge\n"
            metrics+="container_build_json_duration_seconds{feature=\"${feature}\",status=\"${status}\"} ${duration}\n"
        done < "$json_summary"
    fi

    echo -e "$metrics"
}

# ============================================================================
# generate_metrics - Generate all Prometheus metrics
# ============================================================================
generate_metrics() {
    # Add timestamp
    echo "# Container Observability Metrics"
    echo "# Generated at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo ""

    # Collect all metrics
    collect_build_metrics
    collect_runtime_metrics
    collect_json_metrics

    # Add process info metric (always last)
    echo "# HELP container_metrics_scrape_timestamp_seconds Unix timestamp of metrics collection"
    echo "# TYPE container_metrics_scrape_timestamp_seconds gauge"
    echo "container_metrics_scrape_timestamp_seconds $(date +%s)"
}

# ============================================================================
# serve_http - Run simple HTTP server for Prometheus scraping
# ============================================================================
serve_http() {
    local port="$1"

    echo "Starting metrics HTTP server on port ${port}..."
    echo "Metrics endpoint: http://localhost:${port}/metrics"
    echo "Refresh interval: ${METRICS_REFRESH_INTERVAL}s"
    echo ""

    # Try different HTTP server options
    if command -v socat >/dev/null 2>&1; then
        echo "Using socat as HTTP server"
        while true; do
            # Generate metrics and store temporarily
            generate_metrics > /tmp/metrics.prom

            # Serve with socat (TCP server that responds to HTTP requests)
            echo -e "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n$(cat /tmp/metrics.prom)" | \
                socat -T 1 TCP-LISTEN:"${port}",reuseaddr,fork STDIO &

            sleep "$METRICS_REFRESH_INTERVAL"
            pkill -P $$ socat || true
        done
    elif command -v nc >/dev/null 2>&1; then
        echo "Using nc (netcat) as HTTP server"
        while true; do
            generate_metrics > /tmp/metrics.prom

            # Note: This is a simple implementation, may not work with all nc versions
            while true; do
                (echo -e "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n"; cat /tmp/metrics.prom) | \
                    nc -l -p "${port}" -q 1 || break
                sleep 0.1
            done &

            sleep "$METRICS_REFRESH_INTERVAL"
            pkill -P $$ nc || true
        done
    else
        echo "ERROR: No HTTP server available (tried socat, nc)" >&2
        echo "Install socat or nc to run metrics server" >&2
        echo "" >&2
        echo "Fallback: Writing metrics to file instead..." >&2
        serve_file "/tmp/container-metrics.prom"
    fi
}

# ============================================================================
# serve_file - Write metrics to file periodically
# ============================================================================
serve_file() {
    local file="$1"

    echo "Writing metrics to file: ${file}"
    echo "Refresh interval: ${METRICS_REFRESH_INTERVAL}s"
    echo ""

    while true; do
        generate_metrics > "${file}.tmp"
        mv "${file}.tmp" "${file}"
        sleep "$METRICS_REFRESH_INTERVAL"
    done
}

# ============================================================================
# Main
# ============================================================================

main() {
    local mode="stdout"
    local port="$METRICS_PORT"
    local file=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --server)
                mode="server"
                shift
                ;;
            --port)
                port="$2"
                shift 2
                ;;
            --file)
                mode="file"
                file="$2"
                shift 2
                ;;
            --help)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --server           Run HTTP server for Prometheus scraping"
                echo "  --port PORT        Server port (default: 9090)"
                echo "  --file FILE        Write metrics to file instead of HTTP"
                echo "  --help             Show this help message"
                echo ""
                echo "Environment Variables:"
                echo "  METRICS_PORT                Server port (default: 9090)"
                echo "  METRICS_REFRESH_INTERVAL    Refresh interval in seconds (default: 15)"
                echo "  BUILD_LOG_DIR              Build logs directory"
                exit 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                exit 1
                ;;
        esac
    done

    # Execute based on mode
    case "$mode" in
        server)
            serve_http "$port"
            ;;
        file)
            serve_file "$file"
            ;;
        stdout)
            generate_metrics
            ;;
    esac
}

# Run main if executed directly
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
