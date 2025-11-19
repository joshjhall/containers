#!/usr/bin/env bash
# Audit Log Analyzer
# Version: 1.0.0
#
# Description:
#   Analyzes audit logs for security events, anomalies, and compliance
#   violations. Generates summaries and alerts for security incidents.
#
# Usage:
#   ./log-analyzer.sh [options]
#
# Options:
#   --log-path PATH        Path to audit logs
#   --output-path PATH     Path for analysis output
#   --alert-webhook URL    Webhook URL for alerts
#   --summary              Generate daily summary
#   --json                 Output in JSON format
#   --help                 Show this help message
#
# Compliance Coverage:
#   - PCI DSS 10.6: Review logs and security events
#   - HITRUST 09.ab: Monitoring system use
#   - FedRAMP AU-6: Audit review, analysis, and reporting
#   - CMMC AU.L2-3.3.5: Audit record review

set -eo pipefail

# ============================================================================
# Configuration
# ============================================================================

readonly SCRIPT_VERSION="1.0.0"

# Default values
LOG_PATH="/var/log/audit"
OUTPUT_PATH="/var/log/audit-analysis"
ALERT_WEBHOOK=""
GENERATE_SUMMARY=false
JSON_OUTPUT=false

# Alert thresholds
FAILED_AUTH_THRESHOLD=5
PRIVILEGE_ESCALATION_THRESHOLD=1
CONFIG_CHANGE_THRESHOLD=10
ANOMALY_THRESHOLD=100

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# ============================================================================
# Functions
# ============================================================================

usage() {
    sed -n '1,/^$/p' "$0" | tail -n +2 | sed 's/^# //' | sed 's/^#//'
    exit 0
}

log_info() {
    if [ "$JSON_OUTPUT" != "true" ]; then
        echo -e "${BLUE}ℹ${NC} $*"
    fi
}

log_alert() {
    if [ "$JSON_OUTPUT" != "true" ]; then
        echo -e "${RED}⚠${NC} ALERT: $*" >&2
    fi
}

log_warning() {
    if [ "$JSON_OUTPUT" != "true" ]; then
        echo -e "${YELLOW}⚠${NC} $*"
    fi
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --log-path)
                LOG_PATH="$2"
                shift 2
                ;;
            --output-path)
                OUTPUT_PATH="$2"
                shift 2
                ;;
            --alert-webhook)
                ALERT_WEBHOOK="$2"
                shift 2
                ;;
            --summary)
                GENERATE_SUMMARY=true
                shift
                ;;
            --json)
                JSON_OUTPUT=true
                shift
                ;;
            --help|-h)
                usage
                ;;
            *)
                echo "Unknown option: $1" >&2
                usage
                ;;
        esac
    done
}

# Send alert to webhook
send_alert() {
    local severity="$1"
    local title="$2"
    local description="$3"

    if [ -z "$ALERT_WEBHOOK" ]; then
        return 0
    fi

    local payload
    payload=$(cat << EOF
{
  "severity": "$severity",
  "title": "$title",
  "description": "$description",
  "timestamp": "$(date -Iseconds)",
  "source": "audit-log-analyzer"
}
EOF
)

    curl -s -X POST "$ALERT_WEBHOOK" \
        -H "Content-Type: application/json" \
        -d "$payload" > /dev/null 2>&1 || true
}

# Analyze failed authentication attempts
analyze_failed_auth() {
    log_info "Analyzing failed authentication attempts..."

    local count=0
    local pattern="authentication failure|auth.*fail|login.*fail|invalid password"

    if [ -d "$LOG_PATH" ]; then
        count=$(grep -riE "$pattern" "$LOG_PATH" 2>/dev/null | wc -l || echo 0)
    elif [ -f "$LOG_PATH" ]; then
        count=$(grep -iE "$pattern" "$LOG_PATH" 2>/dev/null | wc -l || echo 0)
    fi

    if [ "$count" -ge "$FAILED_AUTH_THRESHOLD" ]; then
        log_alert "High failed authentication count: $count (threshold: $FAILED_AUTH_THRESHOLD)"
        send_alert "high" "Failed Authentication Alert" "Detected $count failed authentication attempts in the last analysis period"
        return 1
    fi

    log_info "Failed authentication attempts: $count"
    return 0
}

# Analyze privilege escalation
analyze_privilege_escalation() {
    log_info "Analyzing privilege escalation events..."

    local count=0
    local pattern="sudo|su -|setuid|setgid|capability|privilege"

    if [ -d "$LOG_PATH" ]; then
        count=$(grep -riE "$pattern" "$LOG_PATH" 2>/dev/null | grep -viE "normal|expected|authorized" | wc -l || echo 0)
    elif [ -f "$LOG_PATH" ]; then
        count=$(grep -iE "$pattern" "$LOG_PATH" 2>/dev/null | grep -viE "normal|expected|authorized" | wc -l || echo 0)
    fi

    if [ "$count" -ge "$PRIVILEGE_ESCALATION_THRESHOLD" ]; then
        log_alert "Privilege escalation detected: $count events"
        send_alert "critical" "Privilege Escalation Alert" "Detected $count privilege escalation events"
        return 1
    fi

    log_info "Privilege escalation events: $count"
    return 0
}

# Analyze configuration changes
analyze_config_changes() {
    log_info "Analyzing configuration changes..."

    local count=0
    local pattern="config.*change|modified|updated|created|deleted|permission.*change"

    if [ -d "$LOG_PATH" ]; then
        count=$(grep -riE "$pattern" "$LOG_PATH" 2>/dev/null | wc -l || echo 0)
    elif [ -f "$LOG_PATH" ]; then
        count=$(grep -iE "$pattern" "$LOG_PATH" 2>/dev/null | wc -l || echo 0)
    fi

    if [ "$count" -ge "$CONFIG_CHANGE_THRESHOLD" ]; then
        log_warning "High configuration change count: $count"
        send_alert "medium" "Configuration Change Alert" "Detected $count configuration changes"
    fi

    log_info "Configuration changes: $count"
    return 0
}

# Analyze access patterns for anomalies
analyze_anomalies() {
    log_info "Analyzing access patterns for anomalies..."

    local count=0
    local pattern="denied|forbidden|unauthorized|blocked|rejected|violation"

    if [ -d "$LOG_PATH" ]; then
        count=$(grep -riE "$pattern" "$LOG_PATH" 2>/dev/null | wc -l || echo 0)
    elif [ -f "$LOG_PATH" ]; then
        count=$(grep -iE "$pattern" "$LOG_PATH" 2>/dev/null | wc -l || echo 0)
    fi

    if [ "$count" -ge "$ANOMALY_THRESHOLD" ]; then
        log_alert "Anomaly detected: $count access denials"
        send_alert "high" "Access Anomaly Alert" "Detected $count access denials/violations"
        return 1
    fi

    log_info "Access anomalies: $count"
    return 0
}

# Generate daily summary
generate_summary() {
    if [ "$GENERATE_SUMMARY" != "true" ]; then
        return 0
    fi

    log_info "Generating daily summary..."

    mkdir -p "$OUTPUT_PATH"

    local summary_file
    summary_file="$OUTPUT_PATH/summary-$(date +%Y%m%d).txt"
    local total_events=0

    if [ -d "$LOG_PATH" ]; then
        total_events=$(find "$LOG_PATH" -type f -name "*.log" -exec cat {} \; 2>/dev/null | wc -l || echo 0)
    elif [ -f "$LOG_PATH" ]; then
        total_events=$(wc -l < "$LOG_PATH" || echo 0)
    fi

    {
        echo "# Audit Log Analysis Summary"
        echo "# Generated: $(date -Iseconds)"
        echo "# Log Path: $LOG_PATH"
        echo "#"
        echo "# Compliance Coverage:"
        echo "#   - PCI DSS 10.6: Review logs and security events"
        echo "#   - FedRAMP AU-6: Audit review, analysis, and reporting"
        echo "#"
        echo "Total Events Analyzed: $total_events"
        echo ""
        echo "## Security Events"
        echo ""

        # Count events by category
        echo "Failed Authentications: $(grep -riE 'auth.*fail|login.*fail' "$LOG_PATH" 2>/dev/null | wc -l || echo 0)"
        echo "Privilege Escalations: $(grep -riE 'sudo|su -|setuid' "$LOG_PATH" 2>/dev/null | wc -l || echo 0)"
        echo "Configuration Changes: $(grep -riE 'config.*change|modified' "$LOG_PATH" 2>/dev/null | wc -l || echo 0)"
        echo "Access Denials: $(grep -riE 'denied|forbidden' "$LOG_PATH" 2>/dev/null | wc -l || echo 0)"
        echo ""
        echo "## Recommendations"
        echo ""
        echo "- Review any privilege escalation events"
        echo "- Investigate failed authentication sources"
        echo "- Verify configuration changes are authorized"

    } > "$summary_file"

    log_info "Summary written to: $summary_file"
}

# Output JSON results
output_json() {
    local failed_auth
    local priv_esc
    local config_changes
    local anomalies

    failed_auth=$(grep -riE 'auth.*fail|login.*fail' "$LOG_PATH" 2>/dev/null | wc -l || echo 0)
    priv_esc=$(grep -riE 'sudo|su -|setuid' "$LOG_PATH" 2>/dev/null | wc -l || echo 0)
    config_changes=$(grep -riE 'config.*change|modified' "$LOG_PATH" 2>/dev/null | wc -l || echo 0)
    anomalies=$(grep -riE 'denied|forbidden' "$LOG_PATH" 2>/dev/null | wc -l || echo 0)

    cat << EOF
{
  "timestamp": "$(date -Iseconds)",
  "log_path": "$LOG_PATH",
  "events": {
    "failed_authentication": $failed_auth,
    "privilege_escalation": $priv_esc,
    "configuration_changes": $config_changes,
    "access_anomalies": $anomalies
  },
  "thresholds": {
    "failed_auth": $FAILED_AUTH_THRESHOLD,
    "privilege_escalation": $PRIVILEGE_ESCALATION_THRESHOLD,
    "config_changes": $CONFIG_CHANGE_THRESHOLD,
    "anomalies": $ANOMALY_THRESHOLD
  },
  "alerts_triggered": $([ "$failed_auth" -ge "$FAILED_AUTH_THRESHOLD" ] || [ "$priv_esc" -ge "$PRIVILEGE_ESCALATION_THRESHOLD" ] || [ "$anomalies" -ge "$ANOMALY_THRESHOLD" ] && echo "true" || echo "false")
}
EOF
}

# ============================================================================
# Main
# ============================================================================

main() {
    parse_args "$@"

    if [ "$JSON_OUTPUT" != "true" ]; then
        echo ""
        echo "================================================================"
        echo "  Audit Log Analyzer v${SCRIPT_VERSION}"
        echo "================================================================"
        echo ""
    fi

    # Run analysis
    local alerts=0
    analyze_failed_auth || alerts=$((alerts + 1))
    analyze_privilege_escalation || alerts=$((alerts + 1))
    analyze_config_changes || true
    analyze_anomalies || alerts=$((alerts + 1))

    # Generate summary if requested
    generate_summary

    # Output results
    if [ "$JSON_OUTPUT" = "true" ]; then
        output_json
    else
        echo ""
        echo "================================================================"
        echo "  Analysis Complete"
        echo "================================================================"
        if [ "$alerts" -gt 0 ]; then
            echo -e "${RED}Alerts triggered: $alerts${NC}"
            exit 1
        else
            echo -e "${GREEN}No critical alerts${NC}"
        fi
    fi
}

main "$@"
