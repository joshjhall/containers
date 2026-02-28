#!/usr/bin/env bash
# Unit tests for compliance validation module
#
# Tests the compliance validation functions in lib/runtime/compliance-validation.sh

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Compliance Validation Module"

# Source the validation framework (provides cv_success/error/warning/info + colors)
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/runtime/validate-config.sh"

# Disable validation auto-run for testing
export VALIDATE_CONFIG=false

# ============================================================================
# Test Setup
# ============================================================================

setup() {
    # Reset validation counters
    # shellcheck disable=SC2034  # Used by sourced validate-config.sh
    CV_ERROR_COUNT=0
    # shellcheck disable=SC2034  # Used by sourced validate-config.sh
    CV_WARNING_COUNT=0

    # Truncate error/warning files
    if [ -n "${CV_ERRORS_FILE:-}" ] && [ -f "$CV_ERRORS_FILE" ]; then
        : > "$CV_ERRORS_FILE"
    fi
    if [ -n "${CV_WARNINGS_FILE:-}" ] && [ -f "$CV_WARNINGS_FILE" ]; then
        : > "$CV_WARNINGS_FILE"
    fi

    # Reset compliance counters
    CV_COMPLIANCE_CHECKS=0
    CV_COMPLIANCE_PASSED=0
    CV_COMPLIANCE_FAILED=0
    CV_COMPLIANCE_REPORT=""

    # Clear compliance-related env vars
    unset TLS_ENABLED SSL_ENABLED TLS_MIN_VERSION SSL_MIN_VERSION 2>/dev/null || true
    unset ENCRYPTION_AT_REST ENCRYPTION_KEY 2>/dev/null || true
    unset ENABLE_AUDIT_LOGGING AUDIT_LOG_FILE LOG_RETENTION_DAYS 2>/dev/null || true
    unset MEMORY_LIMIT CPU_LIMIT 2>/dev/null || true
    unset CONTAINER_PRIVILEGED READ_ONLY_ROOT_FS 2>/dev/null || true
    unset HEALTHCHECK_ENABLED 2>/dev/null || true
    unset NETWORK_POLICY_ENFORCED 2>/dev/null || true
    unset BACKUP_ENABLED BACKUP_SCHEDULE 2>/dev/null || true
    unset COMPLIANCE_MODE COMPLIANCE_REPORT_PATH 2>/dev/null || true
}

teardown() {
    setup
}

# ============================================================================
# cv_compliance_check Tests
# ============================================================================

test_compliance_check_pass() {
    cv_compliance_check "Test Check" "pass" "TEST" "1.0" "Test passed" >/dev/null 2>&1

    assert_equals 1 "$CV_COMPLIANCE_CHECKS" "Should increment total checks"
    assert_equals 1 "$CV_COMPLIANCE_PASSED" "Should increment passed"
    assert_equals 0 "$CV_COMPLIANCE_FAILED" "Should not increment failed"
    assert_contains "$CV_COMPLIANCE_REPORT" "PASS|TEST|1.0|Test Check|Test passed" \
        "Report should contain pass entry"
}

test_compliance_check_fail() {
    cv_compliance_check "Test Check" "fail" "TEST" "2.0" "Test failed" "Fix it" >/dev/null 2>&1

    assert_equals 1 "$CV_COMPLIANCE_CHECKS" "Should increment total checks"
    assert_equals 0 "$CV_COMPLIANCE_PASSED" "Should not increment passed"
    assert_equals 1 "$CV_COMPLIANCE_FAILED" "Should increment failed"
    assert_contains "$CV_COMPLIANCE_REPORT" "FAIL|TEST|2.0|Test Check|Test failed|Fix it" \
        "Report should contain fail entry with remediation"
}

test_compliance_check_warn() {
    cv_compliance_check "Test Check" "warn" "TEST" "3.0" "Test warning" >/dev/null 2>&1

    assert_equals 1 "$CV_COMPLIANCE_CHECKS" "Should increment total checks"
    assert_equals 0 "$CV_COMPLIANCE_PASSED" "Should not increment passed"
    assert_equals 0 "$CV_COMPLIANCE_FAILED" "Should not increment failed"
    assert_contains "$CV_COMPLIANCE_REPORT" "WARN|TEST|3.0|Test Check|Test warning" \
        "Report should contain warn entry"
}

# ============================================================================
# cv_check_encryption Tests
# ============================================================================

test_encryption_tls_enabled() {
    export TLS_ENABLED=true

    cv_check_encryption "TEST" "4.1" >/dev/null 2>&1

    assert_equals 1 "$CV_COMPLIANCE_PASSED" "TLS enabled should pass"
    assert_contains "$CV_COMPLIANCE_REPORT" "PASS|TEST|4.1|TLS Enabled" \
        "Report should show TLS pass"
}

test_encryption_tls_disabled() {
    cv_check_encryption "TEST" "4.1" >/dev/null 2>&1

    assert_equals 1 "$CV_COMPLIANCE_FAILED" "TLS disabled should fail"
    assert_contains "$CV_COMPLIANCE_REPORT" "FAIL|TEST|4.1|TLS Enabled" \
        "Report should show TLS fail"
}

test_encryption_tls_version_good() {
    export TLS_ENABLED=true
    export TLS_MIN_VERSION=1.2

    cv_check_encryption "TEST" "4.1" >/dev/null 2>&1

    assert_contains "$CV_COMPLIANCE_REPORT" "PASS|TEST|4.1|TLS Version" \
        "TLS 1.2 should pass version check"
}

test_encryption_tls_version_bad() {
    export TLS_ENABLED=true
    export TLS_MIN_VERSION=1.1

    cv_check_encryption "TEST" "4.1" >/dev/null 2>&1

    assert_contains "$CV_COMPLIANCE_REPORT" "FAIL|TEST|4.1|TLS Version" \
        "TLS 1.1 should fail version check"
}

test_encryption_at_rest_configured() {
    export TLS_ENABLED=true
    export ENCRYPTION_AT_REST=true

    cv_check_encryption "TEST" "4.1" >/dev/null 2>&1

    assert_contains "$CV_COMPLIANCE_REPORT" "PASS|TEST|4.1|Encryption at Rest" \
        "Encryption at rest should pass when configured"
}

test_encryption_at_rest_not_configured() {
    export TLS_ENABLED=true

    cv_check_encryption "TEST" "4.1" >/dev/null 2>&1

    assert_contains "$CV_COMPLIANCE_REPORT" "WARN|TEST|4.1|Encryption at Rest" \
        "Encryption at rest should warn when not configured"
}

# ============================================================================
# cv_check_audit_logging Tests
# ============================================================================

test_audit_logging_enabled_with_valid_path() {
    export ENABLE_AUDIT_LOGGING=true
    export AUDIT_LOG_FILE="/tmp/audit.log"

    cv_check_audit_logging "TEST" "10.1" >/dev/null 2>&1

    assert_contains "$CV_COMPLIANCE_REPORT" "PASS|TEST|10.1|Audit Logging" \
        "Audit logging should pass when enabled"
    assert_contains "$CV_COMPLIANCE_REPORT" "PASS|TEST|10.1|Audit Log Path" \
        "Audit log path should pass for valid directory"
}

test_audit_logging_disabled() {
    cv_check_audit_logging "TEST" "10.1" >/dev/null 2>&1

    assert_contains "$CV_COMPLIANCE_REPORT" "FAIL|TEST|10.1|Audit Logging" \
        "Audit logging should fail when disabled"
}

test_audit_logging_retention_sufficient() {
    export ENABLE_AUDIT_LOGGING=true
    export LOG_RETENTION_DAYS=90

    cv_check_audit_logging "TEST" "10.1" >/dev/null 2>&1

    assert_contains "$CV_COMPLIANCE_REPORT" "PASS|TEST|10.1|Log Retention" \
        "90-day retention should pass"
}

test_audit_logging_retention_insufficient() {
    export ENABLE_AUDIT_LOGGING=true
    export LOG_RETENTION_DAYS=30

    cv_check_audit_logging "TEST" "10.1" >/dev/null 2>&1

    assert_contains "$CV_COMPLIANCE_REPORT" "WARN|TEST|10.1|Log Retention" \
        "30-day retention should warn"
}

# ============================================================================
# cv_check_resource_limits Tests
# ============================================================================

test_resource_limits_set() {
    export MEMORY_LIMIT=512m
    export CPU_LIMIT=1.0

    cv_check_resource_limits "TEST" "12.1" >/dev/null 2>&1

    assert_contains "$CV_COMPLIANCE_REPORT" "PASS|TEST|12.1|Memory Limit" \
        "Memory limit should pass when set"
    assert_contains "$CV_COMPLIANCE_REPORT" "PASS|TEST|12.1|CPU Limit" \
        "CPU limit should pass when set"
    assert_equals 0 "$CV_COMPLIANCE_FAILED" "No checks should fail"
}

test_resource_limits_unset() {
    cv_check_resource_limits "TEST" "12.1" >/dev/null 2>&1

    assert_contains "$CV_COMPLIANCE_REPORT" "WARN|TEST|12.1|Memory Limit" \
        "Memory limit should warn when unset"
    assert_contains "$CV_COMPLIANCE_REPORT" "WARN|TEST|12.1|CPU Limit" \
        "CPU limit should warn when unset"
}

# ============================================================================
# cv_check_security_context Tests
# ============================================================================

test_security_context_non_root() {
    # Override id -u to return non-root UID
    id() { echo "1000"; }
    export -f id

    cv_check_security_context "TEST" "6.2" >/dev/null 2>&1

    assert_contains "$CV_COMPLIANCE_REPORT" "PASS|TEST|6.2|Non-root User" \
        "Non-root user should pass"

    unset -f id
}

test_security_context_root() {
    # Override id -u to return root UID
    id() { echo "0"; }
    export -f id

    cv_check_security_context "TEST" "6.2" >/dev/null 2>&1

    assert_contains "$CV_COMPLIANCE_REPORT" "FAIL|TEST|6.2|Non-root User" \
        "Root user should fail"

    unset -f id
}

test_security_context_privileged() {
    # Override id to return non-root
    id() { echo "1000"; }
    export -f id

    export CONTAINER_PRIVILEGED=true

    cv_check_security_context "TEST" "6.2" >/dev/null 2>&1

    assert_contains "$CV_COMPLIANCE_REPORT" "FAIL|TEST|6.2|Privileged Mode" \
        "Privileged mode should fail"

    unset -f id
}

test_security_context_readonly_fs() {
    id() { echo "1000"; }
    export -f id

    export READ_ONLY_ROOT_FS=true

    cv_check_security_context "TEST" "6.2" >/dev/null 2>&1

    assert_contains "$CV_COMPLIANCE_REPORT" "PASS|TEST|6.2|Read-only Filesystem" \
        "Read-only filesystem should pass"

    unset -f id
}

# ============================================================================
# cv_check_health_monitoring Tests
# ============================================================================

test_health_monitoring_enabled() {
    export HEALTHCHECK_ENABLED=true

    cv_check_health_monitoring "TEST" "11.4" >/dev/null 2>&1

    assert_contains "$CV_COMPLIANCE_REPORT" "PASS|TEST|11.4|Health Check" \
        "Health check should pass when enabled"
}

test_health_monitoring_not_configured() {
    cv_check_health_monitoring "TEST" "11.4" >/dev/null 2>&1

    assert_contains "$CV_COMPLIANCE_REPORT" "WARN|TEST|11.4|Health Check" \
        "Health check should warn when not configured"
}

# ============================================================================
# cv_check_network_security Tests
# ============================================================================

test_network_security_enforced() {
    export NETWORK_POLICY_ENFORCED=true

    cv_check_network_security "TEST" "SC-7" >/dev/null 2>&1

    assert_contains "$CV_COMPLIANCE_REPORT" "PASS|TEST|SC-7|Network Policy" \
        "Network policy should pass when enforced"
}

test_network_security_not_enforced() {
    cv_check_network_security "TEST" "SC-7" >/dev/null 2>&1

    assert_contains "$CV_COMPLIANCE_REPORT" "WARN|TEST|SC-7|Network Policy" \
        "Network policy should warn when not enforced"
}

# ============================================================================
# cv_check_backup_config Tests
# ============================================================================

test_backup_configured() {
    export BACKUP_ENABLED=true
    export BACKUP_SCHEDULE="0 2 * * *"

    cv_check_backup_config "TEST" "CP-9" >/dev/null 2>&1

    assert_contains "$CV_COMPLIANCE_REPORT" "PASS|TEST|CP-9|Backup Configuration" \
        "Backup should pass when configured"
    assert_contains "$CV_COMPLIANCE_REPORT" "PASS|TEST|CP-9|Backup Schedule" \
        "Backup schedule should pass when set"
}

test_backup_not_configured() {
    cv_check_backup_config "TEST" "CP-9" >/dev/null 2>&1

    assert_contains "$CV_COMPLIANCE_REPORT" "WARN|TEST|CP-9|Backup Configuration" \
        "Backup should warn when not configured"
}

# ============================================================================
# cv_validate_framework Tests
# ============================================================================

test_validate_framework_pci_dss() {
    # Override id for security_context check
    id() { echo "1000"; }
    export -f id

    # Set up passing env for all checks
    export TLS_ENABLED=true
    export ENABLE_AUDIT_LOGGING=true
    export MEMORY_LIMIT=512m
    export HEALTHCHECK_ENABLED=true

    cv_validate_framework "PCI-DSS" >/dev/null 2>&1
    local result=$?

    # PCI-DSS has 5 check groups: encryption, audit_logging, security_context, resource_limits, health_monitoring
    assert_true [ "$CV_COMPLIANCE_CHECKS" -gt 0 ] "Should run compliance checks"
    assert_equals 0 "$result" "Framework validation should succeed"

    unset -f id
}

test_validate_framework_unknown() {
    if cv_validate_framework "UNKNOWN" >/dev/null 2>&1; then
        fail "Unknown framework should return error"
    else
        return 0
    fi
}

test_validate_framework_hipaa() {
    id() { echo "1000"; }
    export -f id

    export TLS_ENABLED=true
    export ENABLE_AUDIT_LOGGING=true
    export HEALTHCHECK_ENABLED=true

    cv_validate_framework "HIPAA" >/dev/null 2>&1

    assert_true [ "$CV_COMPLIANCE_CHECKS" -gt 0 ] "HIPAA should run checks"

    unset -f id
}

# ============================================================================
# cv_validate_compliance Tests
# ============================================================================

test_validate_compliance_empty_mode() {
    unset COMPLIANCE_MODE

    cv_validate_compliance >/dev/null 2>&1
    local result=$?

    assert_equals 0 "$result" "Empty mode should return 0"
    assert_equals 0 "$CV_COMPLIANCE_CHECKS" "No checks should run"
}

test_validate_compliance_valid_mode() {
    id() { echo "1000"; }
    export -f id

    export COMPLIANCE_MODE=hipaa
    export TLS_ENABLED=true
    export ENABLE_AUDIT_LOGGING=true
    export HEALTHCHECK_ENABLED=true
    export BACKUP_ENABLED=true

    cv_validate_compliance >/dev/null 2>&1

    assert_true [ "$CV_COMPLIANCE_CHECKS" -gt 0 ] "Valid mode should run checks"

    unset -f id
}

test_validate_compliance_unknown_mode() {
    export COMPLIANCE_MODE=bogus

    if cv_validate_compliance >/dev/null 2>&1; then
        fail "Unknown compliance mode should return error"
    else
        return 0
    fi
}

# ============================================================================
# cv_generate_compliance_report Tests
# ============================================================================

test_generate_report_writes_file() {
    local tmpdir
    tmpdir=$(mktemp -d)

    export COMPLIANCE_REPORT_PATH="$tmpdir/report.txt"
    export COMPLIANCE_MODE=test

    # Populate some data
    CV_COMPLIANCE_CHECKS=3
    CV_COMPLIANCE_PASSED=2
    CV_COMPLIANCE_FAILED=1
    CV_COMPLIANCE_REPORT="PASS|TEST|1.0|Check1|Desc1\nFAIL|TEST|2.0|Check2|Desc2|Fix\n"

    cv_generate_compliance_report >/dev/null 2>&1

    assert_true [ -f "$tmpdir/report.txt" ] "Report file should be created"

    local content
    content=$(cat "$tmpdir/report.txt")
    assert_contains "$content" "Compliance Validation Report" "Report should have header"
    assert_contains "$content" "Total Checks: 3" "Report should show total checks"
    assert_contains "$content" "Passed: 2" "Report should show passed count"
    assert_contains "$content" "Failed: 1" "Report should show failed count"
    assert_contains "$content" "PASS|TEST|1.0|Check1|Desc1" "Report should include check data"

    rm -rf "$tmpdir"
}

test_generate_report_empty_path_noop() {
    unset COMPLIANCE_REPORT_PATH

    cv_generate_compliance_report >/dev/null 2>&1
    local result=$?

    assert_equals 0 "$result" "Empty report path should be a no-op"
}

test_generate_report_creates_directory() {
    local tmpdir
    tmpdir=$(mktemp -d)
    local nested_path="$tmpdir/nested/dir/report.txt"

    export COMPLIANCE_REPORT_PATH="$nested_path"
    export COMPLIANCE_MODE=test

    cv_generate_compliance_report >/dev/null 2>&1

    assert_true [ -f "$nested_path" ] "Report should create nested directories"

    rm -rf "$tmpdir"
}

# ============================================================================
# Run Tests
# ============================================================================

# cv_compliance_check
run_test test_compliance_check_pass "Compliance check: pass recording"
run_test test_compliance_check_fail "Compliance check: fail recording"
run_test test_compliance_check_warn "Compliance check: warn recording"

# cv_check_encryption
run_test test_encryption_tls_enabled "Encryption: TLS enabled"
run_test test_encryption_tls_disabled "Encryption: TLS disabled"
run_test test_encryption_tls_version_good "Encryption: TLS 1.2 passes"
run_test test_encryption_tls_version_bad "Encryption: TLS 1.1 fails"
run_test test_encryption_at_rest_configured "Encryption: at rest configured"
run_test test_encryption_at_rest_not_configured "Encryption: at rest not configured"

# cv_check_audit_logging
run_test test_audit_logging_enabled_with_valid_path "Audit logging: enabled with valid path"
run_test test_audit_logging_disabled "Audit logging: disabled"
run_test test_audit_logging_retention_sufficient "Audit logging: 90-day retention passes"
run_test test_audit_logging_retention_insufficient "Audit logging: 30-day retention warns"

# cv_check_resource_limits
run_test test_resource_limits_set "Resource limits: set"
run_test test_resource_limits_unset "Resource limits: unset"

# cv_check_security_context
run_test test_security_context_non_root "Security context: non-root user"
run_test test_security_context_root "Security context: root user"
run_test test_security_context_privileged "Security context: privileged mode"
run_test test_security_context_readonly_fs "Security context: read-only filesystem"

# cv_check_health_monitoring
run_test test_health_monitoring_enabled "Health monitoring: enabled"
run_test test_health_monitoring_not_configured "Health monitoring: not configured"

# cv_check_network_security
run_test test_network_security_enforced "Network security: enforced"
run_test test_network_security_not_enforced "Network security: not enforced"

# cv_check_backup_config
run_test test_backup_configured "Backup config: configured"
run_test test_backup_not_configured "Backup config: not configured"

# cv_validate_framework
run_test test_validate_framework_pci_dss "Validate framework: PCI-DSS"
run_test test_validate_framework_unknown "Validate framework: unknown"
run_test test_validate_framework_hipaa "Validate framework: HIPAA"

# cv_validate_compliance
run_test test_validate_compliance_empty_mode "Validate compliance: empty mode"
run_test test_validate_compliance_valid_mode "Validate compliance: valid mode"
run_test test_validate_compliance_unknown_mode "Validate compliance: unknown mode"

# cv_generate_compliance_report
run_test test_generate_report_writes_file "Generate report: writes file"
run_test test_generate_report_empty_path_noop "Generate report: empty path no-op"
run_test test_generate_report_creates_directory "Generate report: creates directory"

# Generate test report
generate_report
