#!/bin/bash
# Anomaly detection for baseline runtime behavior
#
# Description:
#   Compares current runtime behavior metrics against established
#   baseline thresholds to detect anomalies.
#
# Functions:
#   compare_to_baseline() - Compare current behavior to baseline thresholds
#
# Dependencies:
#   - prometheus_query_instant() must be defined before sourcing
#   - log_info(), log_warn(), log_error(), log_success() must be available
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/baseline/anomaly-detection.sh"

# Header guard to prevent multiple sourcing
if [ -n "${_BASELINE_ANOMALY_DETECTION_SH_INCLUDED:-}" ]; then
    return 0
fi
readonly _BASELINE_ANOMALY_DETECTION_SH_INCLUDED=1

# Compare current behavior to baseline
compare_to_baseline() {
    local baseline_file="$1"

    log_info "Comparing current behavior to baseline..."

    if [[ ! -f "$baseline_file" ]]; then
        log_error "Baseline file not found: $baseline_file"
        exit 1
    fi

    local namespace
    namespace=$(jq -r '.metadata.namespace' "$baseline_file")

    # Get current event rates
    local current_process current_network
    current_process=$(prometheus_query_instant "sum(rate(falco_events{k8s_ns_name=\"${namespace}\", rule=~\".*process.*\"}[5m])) * 300" | jq -r '.[0].value[1] // 0')
    current_network=$(prometheus_query_instant "sum(rate(falco_events{k8s_ns_name=\"${namespace}\", rule=~\".*network.*\"}[5m])) * 300" | jq -r '.[0].value[1] // 0')

    local warn_process crit_process warn_network crit_network
    warn_process=$(jq -r '.thresholds.process_executions.warning' "$baseline_file")
    crit_process=$(jq -r '.thresholds.process_executions.critical' "$baseline_file")
    warn_network=$(jq -r '.thresholds.network_events.warning' "$baseline_file")
    crit_network=$(jq -r '.thresholds.network_events.critical' "$baseline_file")

    echo ""
    echo "=== Current vs Baseline Comparison ==="
    echo "Namespace: $namespace"
    echo ""
    echo "Process Executions (5m rate):"
    echo "  Current: ${current_process}"
    echo "  Warning Threshold: ${warn_process}"
    echo "  Critical Threshold: ${crit_process}"

    if (( $(echo "$current_process > $crit_process" | bc -l) )); then
        log_error "  Status: CRITICAL - Process execution rate exceeds critical threshold"
    elif (( $(echo "$current_process > $warn_process" | bc -l) )); then
        log_warn "  Status: WARNING - Process execution rate exceeds warning threshold"
    else
        log_success "  Status: NORMAL"
    fi

    echo ""
    echo "Network Events (5m rate):"
    echo "  Current: ${current_network}"
    echo "  Warning Threshold: ${warn_network}"
    echo "  Critical Threshold: ${crit_network}"

    if (( $(echo "$current_network > $crit_network" | bc -l) )); then
        log_error "  Status: CRITICAL - Network event rate exceeds critical threshold"
    elif (( $(echo "$current_network > $warn_network" | bc -l) )); then
        log_warn "  Status: WARNING - Network event rate exceeds warning threshold"
    else
        log_success "  Status: NORMAL"
    fi
}
