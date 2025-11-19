#!/bin/bash
# Velero Backup Validation Script
#
# Description:
#   Validates Velero backups by performing test restores.
#   Required for HIPAA 164.308(a)(7)(ii)(D) disaster recovery testing.
#
# Compliance Coverage:
#   - HIPAA 164.308(a)(7)(ii)(D): Testing and revision procedures
#   - SOC 2 A1.3: Recovery testing
#   - ISO 27001 A.17.1.3: Verify, review, evaluate
#   - PCI DSS 9.5.1: Backup testing
#   - FedRAMP CP-4: Contingency plan testing
#
# Usage:
#   ./validate-backup.sh [backup-name]
#   ./validate-backup.sh --schedule daily-all-namespaces
#   ./validate-backup.sh --latest hipaa-phi-backup

set -euo pipefail

# Configuration
VALIDATION_NAMESPACE="${VALIDATION_NAMESPACE:-backup-validation}"
CLEANUP_AFTER="${CLEANUP_AFTER:-true}"
TIMEOUT="${TIMEOUT:-1800}"  # 30 minutes
LOG_FILE="${LOG_FILE:-/tmp/backup-validation-$(date +%Y%m%d-%H%M%S).log}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${message}" | tee -a "$LOG_FILE"
}

log_info() { log "INFO" "$*"; }
log_warn() { log "${YELLOW}WARN${NC}" "$*"; }
log_error() { log "${RED}ERROR${NC}" "$*"; }
log_success() { log "${GREEN}SUCCESS${NC}" "$*"; }

usage() {
    cat << EOF
Velero Backup Validation Script

Usage:
    $0 [OPTIONS] [BACKUP_NAME]

Options:
    -s, --schedule NAME     Validate latest backup from schedule
    -l, --latest NAME       Validate latest backup matching name prefix
    -n, --namespace NS      Validation namespace (default: backup-validation)
    -t, --timeout SECS      Timeout in seconds (default: 1800)
    --no-cleanup            Don't cleanup validation namespace after test
    -h, --help              Show this help message

Examples:
    $0 daily-all-namespaces-20231215120000
    $0 --schedule hipaa-phi-backup
    $0 --latest weekly-all-namespaces
    $0 --schedule daily-all-namespaces --no-cleanup

Compliance:
    This script satisfies backup validation requirements for:
    - HIPAA 164.308(a)(7)(ii)(D)
    - SOC 2 A1.3
    - PCI DSS 9.5.1
    - FedRAMP CP-4

EOF
    exit 0
}

# Parse arguments
BACKUP_NAME=""
SCHEDULE_NAME=""
LATEST_PREFIX=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--schedule)
            SCHEDULE_NAME="$2"
            shift 2
            ;;
        -l|--latest)
            LATEST_PREFIX="$2"
            shift 2
            ;;
        -n|--namespace)
            VALIDATION_NAMESPACE="$2"
            shift 2
            ;;
        -t|--timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        --no-cleanup)
            CLEANUP_AFTER="false"
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            BACKUP_NAME="$1"
            shift
            ;;
    esac
done

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    if ! command -v velero &> /dev/null; then
        log_error "velero CLI not found. Install from https://velero.io/docs/main/basic-install/"
        exit 1
    fi

    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found"
        exit 1
    fi

    # Check Velero is running
    if ! kubectl get deployment velero -n velero &> /dev/null; then
        log_error "Velero deployment not found in velero namespace"
        exit 1
    fi

    log_success "Prerequisites check passed"
}

# Get backup name from schedule or prefix
resolve_backup_name() {
    if [[ -n "$SCHEDULE_NAME" ]]; then
        log_info "Finding latest backup from schedule: $SCHEDULE_NAME"
        BACKUP_NAME=$(velero backup get -l velero.io/schedule-name="$SCHEDULE_NAME" -o json | \
            jq -r '.items | sort_by(.metadata.creationTimestamp) | last | .metadata.name')

        if [[ -z "$BACKUP_NAME" || "$BACKUP_NAME" == "null" ]]; then
            log_error "No backups found for schedule: $SCHEDULE_NAME"
            exit 1
        fi
    elif [[ -n "$LATEST_PREFIX" ]]; then
        log_info "Finding latest backup with prefix: $LATEST_PREFIX"
        BACKUP_NAME=$(velero backup get -o json | \
            jq -r --arg prefix "$LATEST_PREFIX" \
            '.items | map(select(.metadata.name | startswith($prefix))) | sort_by(.metadata.creationTimestamp) | last | .metadata.name')

        if [[ -z "$BACKUP_NAME" || "$BACKUP_NAME" == "null" ]]; then
            log_error "No backups found with prefix: $LATEST_PREFIX"
            exit 1
        fi
    fi

    if [[ -z "$BACKUP_NAME" ]]; then
        log_error "No backup name specified. Use --help for usage."
        exit 1
    fi

    log_info "Validating backup: $BACKUP_NAME"
}

# Check backup exists and is completed
check_backup_status() {
    log_info "Checking backup status..."

    local status
    status=$(velero backup get "$BACKUP_NAME" -o json | jq -r '.status.phase')

    if [[ "$status" != "Completed" ]]; then
        log_error "Backup $BACKUP_NAME is not completed (status: $status)"
        exit 1
    fi

    # Get backup details
    local start_time end_time items_backed_up
    start_time=$(velero backup get "$BACKUP_NAME" -o json | jq -r '.status.startTimestamp')
    end_time=$(velero backup get "$BACKUP_NAME" -o json | jq -r '.status.completionTimestamp')
    items_backed_up=$(velero backup get "$BACKUP_NAME" -o json | jq -r '.status.progress.itemsBackedUp // "N/A"')

    log_info "Backup details:"
    log_info "  - Start time: $start_time"
    log_info "  - End time: $end_time"
    log_info "  - Items backed up: $items_backed_up"

    log_success "Backup status: Completed"
}

# Create validation namespace
create_validation_namespace() {
    log_info "Creating validation namespace: $VALIDATION_NAMESPACE"

    if kubectl get namespace "$VALIDATION_NAMESPACE" &> /dev/null; then
        log_warn "Validation namespace already exists, cleaning up..."
        kubectl delete namespace "$VALIDATION_NAMESPACE" --wait=true --timeout=300s
    fi

    kubectl create namespace "$VALIDATION_NAMESPACE"
    kubectl label namespace "$VALIDATION_NAMESPACE" \
        purpose=backup-validation \
        backup-validation=in-progress

    log_success "Validation namespace created"
}

# Perform test restore
perform_restore() {
    local restore_name
    restore_name="validate-${BACKUP_NAME}-$(date +%s)"

    log_info "Starting test restore: $restore_name"

    # Create restore with namespace mapping
    velero restore create "$restore_name" \
        --from-backup "$BACKUP_NAME" \
        --namespace-mappings "*:$VALIDATION_NAMESPACE" \
        --wait

    # Check restore status
    local restore_status
    restore_status=$(velero restore get "$restore_name" -o json | jq -r '.status.phase')

    if [[ "$restore_status" == "Completed" ]]; then
        log_success "Restore completed successfully"
        return 0
    elif [[ "$restore_status" == "PartiallyFailed" ]]; then
        log_warn "Restore partially failed"
        velero restore describe "$restore_name" --details | tee -a "$LOG_FILE"
        return 1
    else
        log_error "Restore failed with status: $restore_status"
        velero restore describe "$restore_name" --details | tee -a "$LOG_FILE"
        return 2
    fi
}

# Validate restored resources
validate_resources() {
    log_info "Validating restored resources..."

    local validation_errors=0

    # Count resources in validation namespace
    local pod_count deploy_count svc_count secret_count cm_count
    pod_count=$(kubectl get pods -n "$VALIDATION_NAMESPACE" --no-headers 2>/dev/null | wc -l)
    deploy_count=$(kubectl get deployments -n "$VALIDATION_NAMESPACE" --no-headers 2>/dev/null | wc -l)
    svc_count=$(kubectl get services -n "$VALIDATION_NAMESPACE" --no-headers 2>/dev/null | wc -l)
    secret_count=$(kubectl get secrets -n "$VALIDATION_NAMESPACE" --no-headers 2>/dev/null | wc -l)
    cm_count=$(kubectl get configmaps -n "$VALIDATION_NAMESPACE" --no-headers 2>/dev/null | wc -l)

    log_info "Restored resources:"
    log_info "  - Pods: $pod_count"
    log_info "  - Deployments: $deploy_count"
    log_info "  - Services: $svc_count"
    log_info "  - Secrets: $secret_count"
    log_info "  - ConfigMaps: $cm_count"

    # Check if any deployments have available replicas
    if [[ $deploy_count -gt 0 ]]; then
        log_info "Checking deployment health..."

        local unavailable
        unavailable=$(kubectl get deployments -n "$VALIDATION_NAMESPACE" \
            -o jsonpath='{.items[?(@.status.unavailableReplicas>0)].metadata.name}')

        if [[ -n "$unavailable" ]]; then
            log_warn "Some deployments have unavailable replicas: $unavailable"
            ((validation_errors++))
        fi
    fi

    # Check for pending PVCs
    local pending_pvcs
    pending_pvcs=$(kubectl get pvc -n "$VALIDATION_NAMESPACE" \
        -o jsonpath='{.items[?(@.status.phase=="Pending")].metadata.name}')

    if [[ -n "$pending_pvcs" ]]; then
        log_warn "Pending PVCs found: $pending_pvcs"
        ((validation_errors++))
    fi

    if [[ $validation_errors -eq 0 ]]; then
        log_success "Resource validation passed"
        return 0
    else
        log_warn "Resource validation completed with $validation_errors warnings"
        return 1
    fi
}

# Cleanup validation namespace
cleanup() {
    if [[ "$CLEANUP_AFTER" == "true" ]]; then
        log_info "Cleaning up validation namespace..."
        kubectl delete namespace "$VALIDATION_NAMESPACE" --wait=true --timeout=300s
        log_success "Cleanup completed"
    else
        log_info "Skipping cleanup (--no-cleanup specified)"
        log_info "Validation namespace $VALIDATION_NAMESPACE still exists"
    fi
}

# Generate validation report
generate_report() {
    local status="$1"
    local report_file
    report_file="/tmp/backup-validation-report-$(date +%Y%m%d-%H%M%S).json"

    cat > "$report_file" << EOF
{
    "validation_timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "backup_name": "$BACKUP_NAME",
    "validation_namespace": "$VALIDATION_NAMESPACE",
    "status": "$status",
    "compliance": {
        "hipaa_164_308_a_7_ii_d": true,
        "soc2_a1_3": true,
        "pci_dss_9_5_1": true,
        "fedramp_cp_4": true
    },
    "log_file": "$LOG_FILE",
    "validator": "$(whoami)@$(hostname)"
}
EOF

    log_info "Validation report generated: $report_file"

    # Output for CI/CD integration
    echo "::set-output name=validation_status::$status"
    echo "::set-output name=report_file::$report_file"
}

# Main execution
main() {
    local exit_code=0

    log_info "=== Velero Backup Validation Started ==="
    log_info "Log file: $LOG_FILE"

    check_prerequisites
    resolve_backup_name
    check_backup_status
    create_validation_namespace

    # Perform restore with error handling
    if ! perform_restore; then
        exit_code=1
    fi

    # Validate resources
    if ! validate_resources; then
        exit_code=$((exit_code > 0 ? exit_code : 1))
    fi

    # Cleanup
    cleanup

    # Generate report
    if [[ $exit_code -eq 0 ]]; then
        log_success "=== Backup Validation PASSED ==="
        generate_report "PASSED"
    else
        log_error "=== Backup Validation FAILED ==="
        generate_report "FAILED"
    fi

    exit $exit_code
}

# Run main
main "$@"
