#!/bin/bash
# Rule generators for baseline runtime behavior
#
# Description:
#   Generates Falco tuning rules and Prometheus alert rules from
#   collected baseline data.
#
# Functions:
#   generate_falco_tuning()  - Generate Falco exception rules from baseline
#   generate_alert_rules()   - Generate Prometheus anomaly alert rules from baseline
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/baseline/rule-generators.sh"

# Header guard to prevent multiple sourcing
if [ -n "${_BASELINE_RULE_GENERATORS_SH_INCLUDED:-}" ]; then
    return 0
fi
readonly _BASELINE_RULE_GENERATORS_SH_INCLUDED=1

# Generate Falco exception rules from baseline
generate_falco_tuning() {
    local baseline_file="$1"
    local output_file="${OUTPUT_DIR}/falco_tuning_rules.yaml"

    log_info "Generating Falco tuning rules from baseline..."

    if [[ ! -f "$baseline_file" ]]; then
        log_error "Baseline file not found: $baseline_file"
        exit 1
    fi

    # Extract commonly triggered rules
    local namespace
    namespace=$(jq -r '.metadata.namespace' "$baseline_file")

    command cat >"$output_file" <<EOF
# Falco Rule Tuning - Generated from Baseline
#
# Namespace: ${namespace}
# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Baseline Duration: $(jq -r '.metadata.duration' "$baseline_file")
#
# These exceptions are based on observed normal behavior.
# Review carefully before applying in production.

# Exception for known processes
- rule: Terminal shell in container
  exceptions:
    - name: known_maintenance_pods
      fields: [container.name, k8s.ns.name]
      comps: [startswith, =]
      values:
        - [[maintenance-], [${namespace}]]

# Process execution thresholds
# Warning threshold: $(jq -r '.thresholds.process_executions.warning' "$baseline_file") events
# Critical threshold: $(jq -r '.thresholds.process_executions.critical' "$baseline_file") events

# Network event thresholds
# Warning threshold: $(jq -r '.thresholds.network_events.warning' "$baseline_file") events
# Critical threshold: $(jq -r '.thresholds.network_events.critical' "$baseline_file") events

# File access thresholds
# Warning threshold: $(jq -r '.thresholds.file_access.warning' "$baseline_file") events
# Critical threshold: $(jq -r '.thresholds.file_access.critical' "$baseline_file") events

# Custom macro for baseline-adjusted behavior
- macro: baseline_adjusted_threshold
  condition: >
    (evt.count < $(jq -r '.thresholds.process_executions.warning' "$baseline_file"))
EOF

    log_success "Falco tuning rules generated: $output_file"
}

# Generate Prometheus alert rules from baseline
generate_alert_rules() {
    local baseline_file="$1"
    local output_file="${OUTPUT_DIR}/anomaly_alerts.yaml"

    log_info "Generating anomaly detection alert rules..."

    local namespace warn_process crit_process warn_network crit_network
    namespace=$(jq -r '.metadata.namespace' "$baseline_file")
    warn_process=$(jq -r '.thresholds.process_executions.warning' "$baseline_file")
    crit_process=$(jq -r '.thresholds.process_executions.critical' "$baseline_file")
    warn_network=$(jq -r '.thresholds.network_events.warning' "$baseline_file")
    crit_network=$(jq -r '.thresholds.network_events.critical' "$baseline_file")

    command cat >"$output_file" <<EOF
# Anomaly Detection Alert Rules - Generated from Baseline
#
# Namespace: ${namespace}
# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
#
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: anomaly-detection-${namespace}
  namespace: monitoring
  labels:
    prometheus: main
    role: alert-rules
spec:
  groups:
    - name: anomaly-detection.${namespace}
      rules:
        - alert: AnomalousProcessExecution
          expr: |
            sum(rate(falco_events{k8s_ns_name="${namespace}", rule=~".*process.*|.*exec.*"}[5m])) * ${RATE_WINDOW_SECONDS:-300} > ${warn_process}
          for: 5m
          labels:
            severity: warning
            namespace: ${namespace}
            compliance: "fedramp-si-4,cmmc-si-l2"
          annotations:
            summary: "Anomalous process execution detected in ${namespace}"
            description: "Process execution rate exceeds baseline threshold ({{ \$value | humanize }} > ${warn_process})"

        - alert: CriticalProcessAnomaly
          expr: |
            sum(rate(falco_events{k8s_ns_name="${namespace}", rule=~".*process.*|.*exec.*"}[5m])) * ${RATE_WINDOW_SECONDS:-300} > ${crit_process}
          for: 2m
          labels:
            severity: critical
            namespace: ${namespace}
            compliance: "fedramp-si-4,cmmc-si-l2"
          annotations:
            summary: "Critical process anomaly in ${namespace}"
            description: "Process execution rate far exceeds baseline ({{ \$value | humanize }} > ${crit_process})"

        - alert: AnomalousNetworkActivity
          expr: |
            sum(rate(falco_events{k8s_ns_name="${namespace}", rule=~".*network.*|.*connection.*"}[5m])) * ${RATE_WINDOW_SECONDS:-300} > ${warn_network}
          for: 5m
          labels:
            severity: warning
            namespace: ${namespace}
            compliance: "fedramp-si-4,cmmc-si-l2"
          annotations:
            summary: "Anomalous network activity in ${namespace}"
            description: "Network event rate exceeds baseline ({{ \$value | humanize }} > ${warn_network})"

        - alert: CriticalNetworkAnomaly
          expr: |
            sum(rate(falco_events{k8s_ns_name="${namespace}", rule=~".*network.*|.*connection.*"}[5m])) * ${RATE_WINDOW_SECONDS:-300} > ${crit_network}
          for: 2m
          labels:
            severity: critical
            namespace: ${namespace}
            compliance: "fedramp-si-4,cmmc-si-l2"
          annotations:
            summary: "Critical network anomaly in ${namespace}"
            description: "Network activity far exceeds baseline ({{ \$value | humanize }} > ${crit_network})"
EOF

    log_success "Anomaly alert rules generated: $output_file"
}
