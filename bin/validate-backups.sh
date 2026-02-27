#!/usr/bin/env bash
# Backup Validation and Testing Script
# Version: 1.0.0
#
# Description:
#   Automated backup validation that verifies backup integrity, tests
#   restorability, and measures RTO/RPO for compliance requirements.
#
# Usage:
#   ./validate-backups.sh [options]
#
# Options:
#   --backup-path PATH     Path to backup files or S3/GCS bucket
#   --restore-path PATH    Temporary path for restore testing
#   --checksum-only        Only verify checksums, skip restore test
#   --report-path PATH     Path to write validation report
#   --rto-target SECONDS   Expected RTO in seconds (default: 3600)
#   --rpo-target SECONDS   Expected RPO in seconds (default: 86400)
#   --json                 Output results in JSON format
#   --help                 Show this help message
#
# Compliance Coverage:
#   - PCI DSS 9.5: Media backup verification
#   - HIPAA §164.308(a)(7)(ii)(A): Data backup plan
#   - FedRAMP CP-9(1): Backup testing
#   - CMMC MA.L2-3.7.2: Maintenance testing

set -eo pipefail

# Get script directory and source verification functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================================
# Configuration
# ============================================================================

readonly SCRIPT_VERSION="1.0.0"

# Default values
BACKUP_PATH=""
RESTORE_PATH="/tmp/backup-restore-test"
CHECKSUM_ONLY=false
REPORT_PATH=""
RTO_TARGET=3600   # 1 hour default
RPO_TARGET=86400  # 24 hours default
JSON_OUTPUT=false

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Results
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
WARNINGS=0

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

log_success() {
    if [ "$JSON_OUTPUT" != "true" ]; then
        echo -e "${GREEN}✓${NC} $*"
    fi
    PASSED_CHECKS=$((PASSED_CHECKS + 1))
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
}

log_error() {
    if [ "$JSON_OUTPUT" != "true" ]; then
        echo -e "${RED}✗${NC} $*" >&2
    fi
    FAILED_CHECKS=$((FAILED_CHECKS + 1))
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
}

log_warning() {
    if [ "$JSON_OUTPUT" != "true" ]; then
        echo -e "${YELLOW}⚠${NC} $*"
    fi
    WARNINGS=$((WARNINGS + 1))
}

# Parse command line arguments (RESTORE_PATH, CHECKSUM_ONLY used by sourced checks.sh)
# shellcheck disable=SC2034
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --backup-path)
                BACKUP_PATH="$2"
                shift 2
                ;;
            --restore-path)
                RESTORE_PATH="$2"
                shift 2
                ;;
            --checksum-only)
                CHECKSUM_ONLY=true
                shift
                ;;
            --report-path)
                REPORT_PATH="$2"
                shift 2
                ;;
            --rto-target)
                RTO_TARGET="$2"
                shift 2
                ;;
            --rpo-target)
                RPO_TARGET="$2"
                shift 2
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

    if [ -z "$BACKUP_PATH" ]; then
        echo "Error: --backup-path is required" >&2
        exit 1
    fi
}

# Verification functions (verify_checksums, verify_rpo, test_restore, verify_completeness)
source "${SCRIPT_DIR}/lib/validate-backups/checks.sh"

# Generate compliance report
generate_report() {
    local report_path="${REPORT_PATH:-/tmp/backup-validation-report-$(date +%Y%m%d-%H%M%S).txt}"

    {
        echo "# Backup Validation Report"
        echo "# Generated: $(date -Iseconds)"
        echo "# Backup Path: $BACKUP_PATH"
        echo "#"
        echo "# Compliance Coverage:"
        echo "#   - PCI DSS 9.5: Media backup verification"
        echo "#   - HIPAA §164.308(a)(7)(ii)(A): Data backup plan"
        echo "#   - FedRAMP CP-9(1): Backup testing"
        echo "#   - CMMC MA.L2-3.7.2: Maintenance testing"
        echo "#"
        echo "# Results Summary"
        echo "# ---------------"
        echo "Total Checks: $TOTAL_CHECKS"
        echo "Passed: $PASSED_CHECKS"
        echo "Failed: $FAILED_CHECKS"
        echo "Warnings: $WARNINGS"
        echo "#"
        echo "# RTO Target: $((RTO_TARGET / 60)) minutes"
        echo "# RPO Target: $((RPO_TARGET / 3600)) hours"
        echo "#"
        if [ "$FAILED_CHECKS" -eq 0 ]; then
            echo "# Overall Status: PASS"
        else
            echo "# Overall Status: FAIL"
        fi
    } > "$report_path"

    log_info "Report written to: $report_path"
}

# Output JSON results
output_json() {
    local status="pass"
    if [ "$FAILED_CHECKS" -gt 0 ]; then
        status="fail"
    fi

    cat << EOF
{
  "timestamp": "$(date -Iseconds)",
  "backup_path": "$BACKUP_PATH",
  "status": "$status",
  "total_checks": $TOTAL_CHECKS,
  "passed": $PASSED_CHECKS,
  "failed": $FAILED_CHECKS,
  "warnings": $WARNINGS,
  "rto_target_seconds": $RTO_TARGET,
  "rpo_target_seconds": $RPO_TARGET,
  "compliance": {
    "pci_dss": "9.5",
    "hipaa": "164.308(a)(7)(ii)(A)",
    "fedramp": "CP-9(1)",
    "cmmc": "MA.L2-3.7.2"
  }
}
EOF
}

# Print summary
print_summary() {
    if [ "$JSON_OUTPUT" = "true" ]; then
        output_json
        return
    fi

    echo ""
    echo "================================================================"
    echo "  Backup Validation Summary"
    echo "================================================================"
    echo "  Backup Path: $BACKUP_PATH"
    echo "  Total Checks: $TOTAL_CHECKS"
    echo -e "  ${GREEN}Passed: $PASSED_CHECKS${NC}"

    if [ "$FAILED_CHECKS" -gt 0 ]; then
        echo -e "  ${RED}Failed: $FAILED_CHECKS${NC}"
    fi

    if [ "$WARNINGS" -gt 0 ]; then
        echo -e "  ${YELLOW}Warnings: $WARNINGS${NC}"
    fi

    echo ""

    if [ "$FAILED_CHECKS" -eq 0 ]; then
        echo -e "${GREEN}✓ Backup validation PASSED${NC}"
        return 0
    else
        echo -e "${RED}✗ Backup validation FAILED${NC}"
        return 1
    fi
}

# ============================================================================
# Main
# ============================================================================

main() {
    parse_args "$@"

    if [ "$JSON_OUTPUT" != "true" ]; then
        echo ""
        echo "================================================================"
        echo "  Backup Validation v${SCRIPT_VERSION}"
        echo "================================================================"
        echo ""
    fi

    # Run validation checks
    verify_checksums || true
    verify_rpo || true
    verify_completeness || true
    test_restore || true

    # Generate report if requested
    if [ -n "$REPORT_PATH" ]; then
        generate_report
    fi

    # Print summary and exit
    print_summary

    if [ "$FAILED_CHECKS" -gt 0 ]; then
        exit 1
    fi
    exit 0
}

main "$@"
