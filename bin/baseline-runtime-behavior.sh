#!/bin/bash
# Runtime Behavior Baseline Collection Script
#
# Description:
#   Collects behavioral metrics from Falco and Prometheus during a baseline
#   period to establish normal behavior patterns for anomaly detection.
#
# Compliance Coverage:
#   - FedRAMP SI-4(5): Automated mechanisms for alerts/notifications
#   - CMMC SI.L2-3.14.2: Security monitoring
#   - CIS Control 8.11: Collect detailed audit logs
#
# Usage:
#   ./baseline-runtime-behavior.sh --duration 30d --namespace production
#   ./baseline-runtime-behavior.sh --analyze --baseline-file baseline.json

set -euo pipefail

# Source extracted library modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/baseline/rule-generators.sh"
source "${SCRIPT_DIR}/lib/baseline/anomaly-detection.sh"

# Configuration
BASELINE_DURATION="${BASELINE_DURATION:-30d}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp/baseline}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://prometheus.monitoring.svc.cluster.local:9090}"
FALCO_NAMESPACE="${FALCO_NAMESPACE:-falco-system}"
WARN_SIGMA="${WARN_SIGMA:-2}"
CRIT_SIGMA="${CRIT_SIGMA:-3}"
RATE_WINDOW_SECONDS="${RATE_WINDOW_SECONDS:-300}"

# Colors
# shellcheck source=lib/shared/colors.sh
source "${SCRIPT_DIR}/../lib/shared/colors.sh" 2>/dev/null ||
    {
        RED='\033[0;31m'
        GREEN='\033[0;32m'
        YELLOW='\033[1;33m'
        BLUE='\033[0;34m'
        NC='\033[0m'
    }

log() {
    local level="$1"
    shift
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') [${level}] $*"
}

log_info() { log "${BLUE}INFO${NC}" "$*"; }
log_warning() { log "${YELLOW}WARN${NC}" "$*"; }
log_error() { log "${RED}ERROR${NC}" "$*"; }
log_success() { log "${GREEN}SUCCESS${NC}" "$*"; }

usage() {
    command cat <<EOF
Runtime Behavior Baseline Collection Script

Usage:
    $0 [OPTIONS]

Collection Options:
    -d, --duration DURATION   Baseline collection duration (default: 30d)
    -n, --namespace NS        Target namespace(s), comma-separated
    -o, --output DIR          Output directory (default: /tmp/baseline)
    --prometheus URL          Prometheus URL
    --start                   Start baseline collection
    --stop                    Stop baseline collection and generate report

Analysis Options:
    --analyze                 Analyze collected baseline data
    --baseline-file FILE      Path to baseline JSON file
    --generate-rules          Generate Falco tuning rules from baseline
    --compare FILE            Compare current behavior to baseline

Other Options:
    -h, --help                Show this help message

Examples:
    # Start 30-day baseline collection for production
    $0 --start --duration 30d --namespace production

    # Analyze collected baseline and generate tuning rules
    $0 --analyze --baseline-file /tmp/baseline/baseline.json --generate-rules

    # Compare current behavior to baseline
    $0 --compare /tmp/baseline/baseline.json

Compliance:
    This script supports anomaly detection requirements for:
    - FedRAMP SI-4(5)
    - CMMC SI.L2-3.14.2
    - CIS Control 8.11

EOF
    exit 0
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    local missing=()

    if ! command -v kubectl &>/dev/null; then
        missing+=("kubectl")
    fi

    if ! command -v jq &>/dev/null; then
        missing+=("jq")
    fi

    if ! command -v curl &>/dev/null; then
        missing+=("curl")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        exit 1
    fi

    # Check Prometheus connectivity
    if ! curl -sf "${PROMETHEUS_URL}/api/v1/status/runtimeinfo" >/dev/null; then
        log_warning "Cannot connect to Prometheus at ${PROMETHEUS_URL}"
    fi

    # Check Falco is running
    if ! kubectl get daemonset -n "$FALCO_NAMESPACE" -l app.kubernetes.io/name=falco &>/dev/null; then
        log_error "Falco not found in namespace $FALCO_NAMESPACE"
        exit 1
    fi

    log_success "Prerequisites check passed"
}

# Query Prometheus
prometheus_query() {
    local query="$1"
    local duration="${2:-$BASELINE_DURATION}"

    curl -sf -G "${PROMETHEUS_URL}/api/v1/query" \
        --data-urlencode "query=${query}[${duration}]" |
        jq -r '.data.result'
}

prometheus_query_instant() {
    local query="$1"

    curl -sf -G "${PROMETHEUS_URL}/api/v1/query" \
        --data-urlencode "query=${query}" |
        jq -r '.data.result'
}

# Collect process execution baseline
collect_process_baseline() {
    local namespace="$1"
    log_info "Collecting process execution baseline for namespace: $namespace"

    local output_file="${OUTPUT_DIR}/process_baseline_${namespace}.json"

    # Query Falco metrics for process executions
    local query="sum by (k8s_pod_name, rule) (increase(falco_events{k8s_ns_name=\"${namespace}\", rule=~\".*process.*|.*exec.*\"}[${BASELINE_DURATION}]))"

    prometheus_query_instant "$query" >"$output_file"

    log_info "Process baseline saved to: $output_file"
}

# Collect network behavior baseline
collect_network_baseline() {
    local namespace="$1"
    log_info "Collecting network behavior baseline for namespace: $namespace"

    local output_file="${OUTPUT_DIR}/network_baseline_${namespace}.json"

    # Network connection patterns
    local query="sum by (k8s_pod_name, rule) (increase(falco_events{k8s_ns_name=\"${namespace}\", rule=~\".*network.*|.*connection.*|.*socket.*\"}[${BASELINE_DURATION}]))"

    prometheus_query_instant "$query" >"$output_file"

    log_info "Network baseline saved to: $output_file"
}

# Collect file access baseline
collect_file_baseline() {
    local namespace="$1"
    log_info "Collecting file access baseline for namespace: $namespace"

    local output_file="${OUTPUT_DIR}/file_baseline_${namespace}.json"

    # File access patterns
    local query="sum by (k8s_pod_name, rule) (increase(falco_events{k8s_ns_name=\"${namespace}\", rule=~\".*file.*|.*read.*|.*write.*|.*modify.*\"}[${BASELINE_DURATION}]))"

    prometheus_query_instant "$query" >"$output_file"

    log_info "File baseline saved to: $output_file"
}

# Collect security event baseline
collect_security_baseline() {
    local namespace="$1"
    log_info "Collecting security event baseline for namespace: $namespace"

    local output_file="${OUTPUT_DIR}/security_baseline_${namespace}.json"

    # All security events by priority
    local query="sum by (priority, rule) (increase(falco_events{k8s_ns_name=\"${namespace}\"}[${BASELINE_DURATION}]))"

    prometheus_query_instant "$query" >"$output_file"

    log_info "Security baseline saved to: $output_file"
}

# Calculate statistics from baseline data
calculate_statistics() {
    local data_file="$1"
    local metric_name="$2"

    if [[ ! -f "$data_file" ]]; then
        echo "{}"
        return
    fi

    # Calculate mean, stddev, min, max
    jq -r --arg metric "$metric_name" '
        [.[].value[1] | tonumber] |
        if length == 0 then
            {($metric): {"mean": 0, "stddev": 0, "min": 0, "max": 0, "count": 0}}
        else
            {
                ($metric): {
                    "mean": (add / length),
                    "stddev": (
                        if length > 1 then
                            ((map(. - (add / length) | . * .) | add) / (length - 1)) | sqrt
                        else
                            0
                        end
                    ),
                    "min": min,
                    "max": max,
                    "count": length
                }
            }
        end
    ' "$data_file"
}

# Generate combined baseline report
generate_baseline_report() {
    local namespace="$1"
    log_info "Generating baseline report for namespace: $namespace"

    local report_file="${OUTPUT_DIR}/baseline_report_${namespace}.json"

    # Combine all statistics
    local process_stats network_stats file_stats security_stats
    process_stats=$(calculate_statistics "${OUTPUT_DIR}/process_baseline_${namespace}.json" "process_executions")
    network_stats=$(calculate_statistics "${OUTPUT_DIR}/network_baseline_${namespace}.json" "network_events")
    file_stats=$(calculate_statistics "${OUTPUT_DIR}/file_baseline_${namespace}.json" "file_access")
    security_stats=$(calculate_statistics "${OUTPUT_DIR}/security_baseline_${namespace}.json" "security_events")

    # Generate report
    jq -n \
        --arg ns "$namespace" \
        --arg duration "$BASELINE_DURATION" \
        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson process "$process_stats" \
        --argjson network "$network_stats" \
        --argjson file "$file_stats" \
        --argjson security "$security_stats" \
        --argjson warn_sigma "$WARN_SIGMA" \
        --argjson crit_sigma "$CRIT_SIGMA" \
        '{
            "metadata": {
                "namespace": $ns,
                "duration": $duration,
                "generated_at": $timestamp,
                "compliance": ["FedRAMP SI-4(5)", "CMMC SI.L2-3.14.2", "CIS Control 8.11"]
            },
            "baseline": {
                "process_executions": $process.process_executions,
                "network_events": $network.network_events,
                "file_access": $file.file_access,
                "security_events": $security.security_events
            },
            "thresholds": {
                "process_executions": {
                    "warning": (($process.process_executions.mean + $process.process_executions.stddev * $warn_sigma) | floor),
                    "critical": (($process.process_executions.mean + $process.process_executions.stddev * $crit_sigma) | floor)
                },
                "network_events": {
                    "warning": (($network.network_events.mean + $network.network_events.stddev * $warn_sigma) | floor),
                    "critical": (($network.network_events.mean + $network.network_events.stddev * $crit_sigma) | floor)
                },
                "file_access": {
                    "warning": (($file.file_access.mean + $file.file_access.stddev * $warn_sigma) | floor),
                    "critical": (($file.file_access.mean + $file.file_access.stddev * $crit_sigma) | floor)
                }
            }
        }' >"$report_file"

    log_success "Baseline report generated: $report_file"
    command cat "$report_file"
}

# Start baseline collection
start_baseline() {
    local namespaces=("$@")

    log_info "Starting baseline collection for ${BASELINE_DURATION}..."
    log_info "Target namespaces: ${namespaces[*]}"

    mkdir -p "$OUTPUT_DIR"

    # Record start time
    date -u +%Y-%m-%dT%H:%M:%SZ >"${OUTPUT_DIR}/baseline_start"

    for ns in "${namespaces[@]}"; do
        collect_process_baseline "$ns"
        collect_network_baseline "$ns"
        collect_file_baseline "$ns"
        collect_security_baseline "$ns"
        generate_baseline_report "$ns"
    done

    log_success "Baseline collection complete"
    log_info "Results saved to: $OUTPUT_DIR"
}

# Analyze baseline and generate recommendations
analyze_baseline() {
    local baseline_file="$1"
    local generate_rules="${2:-false}"

    log_info "Analyzing baseline: $baseline_file"

    if [[ ! -f "$baseline_file" ]]; then
        log_error "Baseline file not found: $baseline_file"
        exit 1
    fi

    # Display baseline summary
    echo ""
    echo "=== Baseline Summary ==="
    jq -r '
        "Namespace: \(.metadata.namespace)",
        "Duration: \(.metadata.duration)",
        "Generated: \(.metadata.generated_at)",
        "",
        "Process Executions:",
        "  Mean: \(.baseline.process_executions.mean // 0 | floor)",
        "  Std Dev: \(.baseline.process_executions.stddev // 0 | floor)",
        "  Warning Threshold: \(.thresholds.process_executions.warning)",
        "  Critical Threshold: \(.thresholds.process_executions.critical)",
        "",
        "Network Events:",
        "  Mean: \(.baseline.network_events.mean // 0 | floor)",
        "  Std Dev: \(.baseline.network_events.stddev // 0 | floor)",
        "  Warning Threshold: \(.thresholds.network_events.warning)",
        "  Critical Threshold: \(.thresholds.network_events.critical)",
        "",
        "File Access:",
        "  Mean: \(.baseline.file_access.mean // 0 | floor)",
        "  Std Dev: \(.baseline.file_access.stddev // 0 | floor)",
        "  Warning Threshold: \(.thresholds.file_access.warning)",
        "  Critical Threshold: \(.thresholds.file_access.critical)"
    ' "$baseline_file"

    if [[ "$generate_rules" == "true" ]]; then
        generate_falco_tuning "$baseline_file"
        generate_alert_rules "$baseline_file"
    fi
}

# Parse arguments
ACTION=""
NAMESPACES=()
BASELINE_FILE=""
GENERATE_RULES="false"
COMPARE_FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -d | --duration)
            BASELINE_DURATION="$2"
            shift 2
            ;;
        -n | --namespace)
            IFS=',' read -ra NAMESPACES <<<"$2"
            shift 2
            ;;
        -o | --output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --prometheus)
            PROMETHEUS_URL="$2"
            shift 2
            ;;
        --start)
            ACTION="start"
            shift
            ;;
        --stop)
            ACTION="stop"
            shift
            ;;
        --analyze)
            ACTION="analyze"
            shift
            ;;
        --baseline-file)
            BASELINE_FILE="$2"
            shift 2
            ;;
        --generate-rules)
            GENERATE_RULES="true"
            shift
            ;;
        --compare)
            ACTION="compare"
            COMPARE_FILE="$2"
            shift 2
            ;;
        -h | --help)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Main execution
main() {
    check_prerequisites

    case "$ACTION" in
        start)
            if [[ ${#NAMESPACES[@]} -eq 0 ]]; then
                NAMESPACES=("production")
            fi
            start_baseline "${NAMESPACES[@]}"
            ;;
        analyze)
            if [[ -z "$BASELINE_FILE" ]]; then
                log_error "Baseline file required for analysis"
                usage
            fi
            analyze_baseline "$BASELINE_FILE" "$GENERATE_RULES"
            ;;
        compare)
            if [[ -z "$COMPARE_FILE" ]]; then
                log_error "Baseline file required for comparison"
                usage
            fi
            compare_to_baseline "$COMPARE_FILE"
            ;;
        *)
            log_error "No action specified"
            usage
            ;;
    esac
}

main "$@"
