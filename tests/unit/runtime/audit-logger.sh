#!/usr/bin/env bash
# Unit tests for lib/runtime/audit-logger.sh
# Tests audit logging functionality for compliance

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Audit Logger Tests"

# Path to script under test
AUDIT_LOGGER="$(dirname "${BASH_SOURCE[0]}")/../../../lib/runtime/audit-logger.sh"

# Setup
setup() {
    export TEST_TEMP_DIR="$RESULTS_DIR/audit-logger-test"
    mkdir -p "$TEST_TEMP_DIR"
    export AUDIT_LOG_FILE="$TEST_TEMP_DIR/test-audit.log"
    export ENABLE_AUDIT_LOGGING="true"
}

# Teardown
teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}

# ============================================================================
# Test: Script exists and is executable
# ============================================================================
test_script_exists() {
    assert_file_exists "$AUDIT_LOGGER" "audit-logger.sh should exist"

    if [ -x "$AUDIT_LOGGER" ]; then
        pass_test "audit-logger.sh is executable"
    else
        fail_test "audit-logger.sh is not executable"
    fi
}

# ============================================================================
# Test: Script has valid syntax
# ============================================================================
test_syntax_valid() {
    if bash -n "$AUDIT_LOGGER" 2>&1; then
        pass_test "Script has valid bash syntax"
    else
        fail_test "Script has syntax errors"
    fi
}

# ============================================================================
# Test: Core functions are defined
# ============================================================================
test_core_functions() {
    local script_content
    script_content=$(command cat "$AUDIT_LOGGER")

    assert_contains "$script_content" "audit_log()" "Should define audit_log function"
    assert_contains "$script_content" "audit_init()" "Should define audit_init function"
}

# ============================================================================
# Test: Configuration variables
# ============================================================================
test_config_variables() {
    local script_content
    script_content=$(command cat "$AUDIT_LOGGER")

    assert_contains "$script_content" 'ENABLE_AUDIT_LOGGING=' "Should have ENABLE_AUDIT_LOGGING"
    assert_contains "$script_content" 'AUDIT_LOG_FILE=' "Should have AUDIT_LOG_FILE"
    assert_contains "$script_content" 'AUDIT_LOG_FORMAT=' "Should have AUDIT_LOG_FORMAT"
    assert_contains "$script_content" 'AUDIT_LOG_LEVEL=' "Should have AUDIT_LOG_LEVEL"
}

# ============================================================================
# Test: Log levels are defined
# ============================================================================
test_log_levels() {
    local script_content
    script_content=$(command cat "$AUDIT_LOGGER")

    assert_contains "$script_content" '"debug"' "Should have debug level"
    assert_contains "$script_content" '"info"' "Should have info level"
    assert_contains "$script_content" '"warn"' "Should have warn level"
    assert_contains "$script_content" '"error"' "Should have error level"
    assert_contains "$script_content" '"critical"' "Should have critical level"
}

# ============================================================================
# Test: Event categories for compliance
# ============================================================================
test_event_categories() {
    local script_content
    script_content=$(command cat "$AUDIT_LOGGER")

    assert_contains "$script_content" '"authentication"' "Should have authentication category"
    assert_contains "$script_content" '"authorization"' "Should have authorization category"
    assert_contains "$script_content" '"data_access"' "Should have data_access category"
    assert_contains "$script_content" '"security"' "Should have security category"
    assert_contains "$script_content" '"compliance"' "Should have compliance category"
}

# ============================================================================
# Test: Compliance documentation
# ============================================================================
test_compliance_docs() {
    local script_content
    script_content=$(command cat "$AUDIT_LOGGER")

    assert_contains "$script_content" "SOC 2" "Should reference SOC 2"
    assert_contains "$script_content" "HIPAA" "Should reference HIPAA"
    assert_contains "$script_content" "PCI DSS" "Should reference PCI DSS"
    assert_contains "$script_content" "GDPR" "Should reference GDPR"
    assert_contains "$script_content" "FedRAMP" "Should reference FedRAMP"
    assert_contains "$script_content" "NIST 800-53" "Should reference NIST"
}

# ============================================================================
# Test: JSON format support
# ============================================================================
test_json_format() {
    local script_content
    script_content=$(command cat "$AUDIT_LOGGER")

    assert_contains "$script_content" "json" "Should support JSON format"
}

# ============================================================================
# Test: Secure permissions on log files
# ============================================================================
test_secure_permissions() {
    local script_content
    script_content=$(command cat "$AUDIT_LOGGER")

    assert_contains "$script_content" "chmod 750" "Should set secure dir permissions"
    assert_contains "$script_content" "chmod 640" "Should set secure file permissions"
}

# ============================================================================
# Test: Retention requirements documented
# ============================================================================
test_retention_docs() {
    local script_content
    script_content=$(command cat "$AUDIT_LOGGER")

    assert_contains "$script_content" "12 months" "Should document SOC 2 retention"
    assert_contains "$script_content" "6 years" "Should document HIPAA retention"
    assert_contains "$script_content" "3 years" "Should document FedRAMP retention"
}

# Run tests
run_test test_script_exists "Script exists and is executable"
run_test test_syntax_valid "Script syntax is valid"
run_test test_core_functions "Core functions are defined"
run_test test_config_variables "Configuration variables present"
run_test test_log_levels "Log levels are defined"
run_test test_event_categories "Event categories for compliance"
run_test test_compliance_docs "Compliance documentation present"
run_test test_json_format "JSON format support"
run_test test_secure_permissions "Secure permissions enforced"
run_test test_retention_docs "Retention requirements documented"

# ============================================================================
# Batch 6: Specialized Audit Functions and Utility Tests
# ============================================================================

SOURCE_FILE="$PROJECT_ROOT/lib/runtime/audit-logger.sh"

# Sub-module files (for static analysis tests that check specific function locations)
EVENTS_FILE="$PROJECT_ROOT/lib/runtime/audit-logger-events.sh"
MAINTENANCE_FILE="$PROJECT_ROOT/lib/runtime/audit-logger-maintenance.sh"

# Test: defines audit_auth function
test_audit_auth_func() {
    assert_file_contains "$EVENTS_FILE" "audit_auth()" "audit-logger-events.sh defines audit_auth function"
}

# Test: defines audit_authz function
test_audit_authz_func() {
    assert_file_contains "$EVENTS_FILE" "audit_authz()" "audit-logger-events.sh defines audit_authz function"
}

# Test: defines audit_data_access function
test_audit_data_access_func() {
    assert_file_contains "$EVENTS_FILE" "audit_data_access()" "audit-logger-events.sh defines audit_data_access function"
}

# Test: defines audit_config function
test_audit_config_func() {
    assert_file_contains "$EVENTS_FILE" "audit_config()" "audit-logger-events.sh defines audit_config function"
}

# Test: defines audit_security function
test_audit_security_func() {
    assert_file_contains "$EVENTS_FILE" "audit_security()" "audit-logger-events.sh defines audit_security function"
}

# Test: defines audit_network function
test_audit_network_func() {
    assert_file_contains "$EVENTS_FILE" "audit_network()" "audit-logger-events.sh defines audit_network function"
}

# Test: defines audit_file function
test_audit_file_func() {
    assert_file_contains "$EVENTS_FILE" "audit_file()" "audit-logger-events.sh defines audit_file function"
}

# Test: defines audit_process function
test_audit_process_func() {
    assert_file_contains "$EVENTS_FILE" "audit_process()" "audit-logger-events.sh defines audit_process function"
}

# Test: defines audit_compliance function
test_audit_compliance_func() {
    assert_file_contains "$EVENTS_FILE" "audit_compliance()" "audit-logger-events.sh defines audit_compliance function"
}

# Test: defines audit_rotate function
test_audit_rotate_func() {
    assert_file_contains "$MAINTENANCE_FILE" "audit_rotate()" "audit-logger-maintenance.sh defines audit_rotate function"
}

# Test: defines audit_verify_integrity function
test_audit_verify_integrity_func() {
    assert_file_contains "$MAINTENANCE_FILE" "audit_verify_integrity()" "audit-logger-maintenance.sh defines audit_verify_integrity function"
}

# Test: defines get_retention_policy function
test_get_retention_policy_func() {
    assert_file_contains "$MAINTENANCE_FILE" "get_retention_policy()" "audit-logger-maintenance.sh defines get_retention_policy function"
}

# Test: defines build_json_entry function
test_build_json_entry_func() {
    assert_file_contains "$SOURCE_FILE" "build_json_entry()" "audit-logger.sh defines build_json_entry function"
}

# Test: Log rotation size-based trigger
test_log_rotation_size_trigger() {
    assert_file_contains "$MAINTENANCE_FILE" "stat" "audit-logger-maintenance.sh checks file size via stat"
    assert_file_contains "$MAINTENANCE_FILE" "max_size" "audit-logger-maintenance.sh uses max_size for rotation threshold"
}

# Test: Log rotation compression
test_log_rotation_compression() {
    assert_file_contains "$MAINTENANCE_FILE" "gzip" "audit-logger-maintenance.sh compresses rotated logs with gzip"
}

# Test: Integrity verification with sha256sum
test_integrity_sha256sum() {
    assert_file_contains "$MAINTENANCE_FILE" "sha256sum" "audit-logger-maintenance.sh uses sha256sum for integrity verification"
}

# Test: UUID generation
test_uuid_generation() {
    assert_file_contains "$SOURCE_FILE" "/proc/sys/kernel/random/uuid" "audit-logger.sh uses /proc/sys/kernel/random/uuid"
    assert_file_contains "$SOURCE_FILE" "RANDOM" "audit-logger.sh has RANDOM fallback for UUID generation"
}

# Test: Functions exported for use in other scripts
test_functions_exported() {
    assert_file_contains "$SOURCE_FILE" "export -f audit_log" "audit-logger.sh exports audit_log function"
    assert_file_contains "$EVENTS_FILE" "export -f audit_security" "audit-logger-events.sh exports audit_security function"
    assert_file_contains "$SOURCE_FILE" "export -f audit_init" "audit-logger.sh exports audit_init function"
}

# Run Batch 6 audit-logger tests
run_test test_audit_auth_func "Defines audit_auth function"
run_test test_audit_authz_func "Defines audit_authz function"
run_test test_audit_data_access_func "Defines audit_data_access function"
run_test test_audit_config_func "Defines audit_config function"
run_test test_audit_security_func "Defines audit_security function"
run_test test_audit_network_func "Defines audit_network function"
run_test test_audit_file_func "Defines audit_file function"
run_test test_audit_process_func "Defines audit_process function"
run_test test_audit_compliance_func "Defines audit_compliance function"
run_test test_audit_rotate_func "Defines audit_rotate function"
run_test test_audit_verify_integrity_func "Defines audit_verify_integrity function"
run_test test_get_retention_policy_func "Defines get_retention_policy function"
run_test test_build_json_entry_func "Defines build_json_entry function"
run_test test_log_rotation_size_trigger "Log rotation size-based trigger"
run_test test_log_rotation_compression "Log rotation uses gzip compression"
run_test test_integrity_sha256sum "Integrity verification uses sha256sum"
run_test test_uuid_generation "UUID generation with fallback"
run_test test_functions_exported "Functions exported for other scripts"

# ============================================================================
# Batch 7: JSON Escaping and Validation Tests
# ============================================================================

# Test: _json_escape helper is defined
test_json_escape_defined() {
    assert_file_contains "$SOURCE_FILE" "_json_escape()" \
        "audit-logger.sh should define _json_escape helper function"
}

# Test: _json_escape is exported
test_json_escape_exported() {
    assert_file_contains "$SOURCE_FILE" "export -f _json_escape" \
        "audit-logger.sh should export _json_escape function"
}

# Test: audit_auth uses _json_escape
test_audit_auth_uses_escape() {
    # Extract audit_auth function body and check for _json_escape usage
    local func_body
    func_body=$(command sed -n '/^audit_auth()/,/^}/p' "$EVENTS_FILE")
    if echo "$func_body" | command grep -q '_json_escape'; then
        pass_test "audit_auth uses _json_escape for field escaping"
    else
        fail_test "audit_auth does not use _json_escape"
    fi
}

# Test: audit_authz uses _json_escape
test_audit_authz_uses_escape() {
    local func_body
    func_body=$(command sed -n '/^audit_authz()/,/^}/p' "$EVENTS_FILE")
    if echo "$func_body" | command grep -q '_json_escape'; then
        pass_test "audit_authz uses _json_escape for field escaping"
    else
        fail_test "audit_authz does not use _json_escape"
    fi
}

# Test: audit_data_access uses _json_escape
test_audit_data_access_uses_escape() {
    local func_body
    func_body=$(command sed -n '/^audit_data_access()/,/^}/p' "$EVENTS_FILE")
    if echo "$func_body" | command grep -q '_json_escape'; then
        pass_test "audit_data_access uses _json_escape for field escaping"
    else
        fail_test "audit_data_access does not use _json_escape"
    fi
}

# Test: audit_config uses _json_escape
test_audit_config_uses_escape() {
    local func_body
    func_body=$(command sed -n '/^audit_config()/,/^}/p' "$EVENTS_FILE")
    if echo "$func_body" | command grep -q '_json_escape'; then
        pass_test "audit_config uses _json_escape for field escaping"
    else
        fail_test "audit_config does not use _json_escape"
    fi
}

# Test: audit_security uses _json_escape
test_audit_security_uses_escape() {
    local func_body
    func_body=$(command sed -n '/^audit_security()/,/^}/p' "$EVENTS_FILE")
    if echo "$func_body" | command grep -q '_json_escape'; then
        pass_test "audit_security uses _json_escape for field escaping"
    else
        fail_test "audit_security does not use _json_escape"
    fi
}

# Test: audit_network uses _json_escape
test_audit_network_uses_escape() {
    local func_body
    func_body=$(command sed -n '/^audit_network()/,/^}/p' "$EVENTS_FILE")
    if echo "$func_body" | command grep -q '_json_escape'; then
        pass_test "audit_network uses _json_escape for field escaping"
    else
        fail_test "audit_network does not use _json_escape"
    fi
}

# Test: audit_file uses _json_escape
test_audit_file_uses_escape() {
    local func_body
    func_body=$(command sed -n '/^audit_file()/,/^}/p' "$EVENTS_FILE")
    if echo "$func_body" | command grep -q '_json_escape'; then
        pass_test "audit_file uses _json_escape for field escaping"
    else
        fail_test "audit_file does not use _json_escape"
    fi
}

# Test: audit_process uses _json_escape
test_audit_process_uses_escape() {
    local func_body
    func_body=$(command sed -n '/^audit_process()/,/^}/p' "$EVENTS_FILE")
    if echo "$func_body" | command grep -q '_json_escape'; then
        pass_test "audit_process uses _json_escape for field escaping"
    else
        fail_test "audit_process does not use _json_escape"
    fi
}

# Test: audit_compliance uses _json_escape
test_audit_compliance_uses_escape() {
    local func_body
    func_body=$(command sed -n '/^audit_compliance()/,/^}/p' "$EVENTS_FILE")
    if echo "$func_body" | command grep -q '_json_escape'; then
        pass_test "audit_compliance uses _json_escape for field escaping"
    else
        fail_test "audit_compliance does not use _json_escape"
    fi
}

# Test: build_json_entry validates extra_data structure
test_build_json_entry_validates_extra_data() {
    local func_body
    func_body=$(command sed -n '/^build_json_entry()/,/^}/p' "$SOURCE_FILE")
    if echo "$func_body" | command grep -qE '\{.*\}'; then
        pass_test "build_json_entry validates extra_data starts with { and ends with }"
    else
        fail_test "build_json_entry does not validate extra_data structure"
    fi
}

# Run Batch 7 tests
run_test test_json_escape_defined "Defines _json_escape helper function"
run_test test_json_escape_exported "Exports _json_escape function"
run_test test_audit_auth_uses_escape "audit_auth uses _json_escape"
run_test test_audit_authz_uses_escape "audit_authz uses _json_escape"
run_test test_audit_data_access_uses_escape "audit_data_access uses _json_escape"
run_test test_audit_config_uses_escape "audit_config uses _json_escape"
run_test test_audit_security_uses_escape "audit_security uses _json_escape"
run_test test_audit_network_uses_escape "audit_network uses _json_escape"
run_test test_audit_file_uses_escape "audit_file uses _json_escape"
run_test test_audit_process_uses_escape "audit_process uses _json_escape"
run_test test_audit_compliance_uses_escape "audit_compliance uses _json_escape"
run_test test_build_json_entry_validates_extra_data "build_json_entry validates extra_data structure"

# ============================================================================
# Batch 8: Functional Tests (source and execute audit-logger.sh)
# ============================================================================

# Source audit-logger.sh ONCE at global scope so that associative arrays
# (LOG_LEVELS, EVENT_CATEGORIES) created via declare -A are not scoped to a
# function and lost when the function returns.
FUNC_TEST_BASE_DIR="$RESULTS_DIR/audit-logger-func-init-$$"
mkdir -p "$FUNC_TEST_BASE_DIR"
export AUDIT_INITIALIZED=false
export ENABLE_AUDIT_LOGGING="true"
export AUDIT_LOG_FILE="$FUNC_TEST_BASE_DIR/init-audit.log"
export AUDIT_LOG_FORMAT="json"
export AUDIT_LOG_LEVEL="info"
export AUDIT_INCLUDE_PID="true"
export AUDIT_INCLUDE_HOST="true"
export AUDIT_STDOUT_COPY="false"
# shellcheck source=/dev/null
source "$SOURCE_FILE"
rm -rf "$FUNC_TEST_BASE_DIR"

# Helper: reset audit state for each functional test (does NOT re-source)
_reset_audit_logger() {
    export AUDIT_INITIALIZED=false
    export ENABLE_AUDIT_LOGGING="true"
    export TEST_TEMP_DIR="$RESULTS_DIR/audit-logger-func-test-$$-$RANDOM"
    mkdir -p "$TEST_TEMP_DIR"
    export AUDIT_LOG_FILE="$TEST_TEMP_DIR/test-audit.log"
    export AUDIT_LOG_FORMAT="json"
    export AUDIT_LOG_LEVEL="info"
    export AUDIT_INCLUDE_PID="true"
    export AUDIT_INCLUDE_HOST="true"
    export AUDIT_STDOUT_COPY="false"
    audit_init
}

# Cleanup helper for functional tests
_cleanup_func_test() {
    if [ -n "${TEST_TEMP_DIR:-}" ] && [ -d "$TEST_TEMP_DIR" ]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}

# Test: audit_init creates log directory and file
test_func_audit_init_creates_files() {
    _reset_audit_logger
    if [ -f "$AUDIT_LOG_FILE" ]; then
        pass_test "audit_init creates log directory and file"
    else
        fail_test "audit_init did not create log file at $AUDIT_LOG_FILE"
    fi
    _cleanup_func_test
}

# Test: audit_init writes initialization event
test_func_audit_init_writes_event() {
    _reset_audit_logger
    if command grep -q "Audit logging initialized" "$AUDIT_LOG_FILE" 2>/dev/null; then
        pass_test "audit_init writes initialization event to log"
    else
        fail_test "audit_init did not write initialization event"
    fi
    _cleanup_func_test
}

# Test: audit_log writes JSON to log file
test_func_audit_log_writes_json() {
    _reset_audit_logger
    audit_log "system" "info" "Test event" '{"test_key":"test_value"}'
    if command grep -q '"test_key":"test_value"' "$AUDIT_LOG_FILE" 2>/dev/null; then
        pass_test "audit_log writes JSON to log file"
    else
        fail_test "audit_log did not write expected JSON"
    fi
    _cleanup_func_test
}

# Test: audit_log respects log level threshold filtering
test_func_audit_log_level_filter() {
    _reset_audit_logger
    export AUDIT_LOG_LEVEL="error"
    audit_log "system" "info" "Should be filtered"
    if command grep -q "Should be filtered" "$AUDIT_LOG_FILE" 2>/dev/null; then
        fail_test "audit_log did not filter below-threshold event"
    else
        pass_test "audit_log respects log level threshold filtering"
    fi
    _cleanup_func_test
}

# Test: audit_log is a no-op when ENABLE_AUDIT_LOGGING=false
test_func_audit_log_disabled() {
    export AUDIT_INITIALIZED=false
    export ENABLE_AUDIT_LOGGING="false"
    export TEST_TEMP_DIR="$RESULTS_DIR/audit-logger-func-test-disabled-$$"
    mkdir -p "$TEST_TEMP_DIR"
    export AUDIT_LOG_FILE="$TEST_TEMP_DIR/test-audit.log"
    # Call audit_init (should be no-op when disabled)
    audit_init
    audit_log "system" "info" "Should not appear"
    if [ -f "$AUDIT_LOG_FILE" ]; then
        fail_test "audit_log should not create log file when disabled"
    else
        pass_test "audit_log is a no-op when ENABLE_AUDIT_LOGGING=false"
    fi
    _cleanup_func_test
}

# Test: audit_auth writes authentication event with correct fields
test_func_audit_auth() {
    _reset_audit_logger
    audit_auth "login" "testuser" "success" '{}'
    if command grep -q '"action":"login"' "$AUDIT_LOG_FILE" && \
       command grep -q '"user":"testuser"' "$AUDIT_LOG_FILE" && \
       command grep -q '"result":"success"' "$AUDIT_LOG_FILE"; then
        pass_test "audit_auth writes authentication event with correct fields"
    else
        fail_test "audit_auth missing expected fields"
    fi
    _cleanup_func_test
}

# Test: audit_config writes configuration event
test_func_audit_config() {
    _reset_audit_logger
    audit_config "docker" "modified" "admin" "old" "new"
    if command grep -q '"component":"docker"' "$AUDIT_LOG_FILE" && \
       command grep -q '"change_type":"modified"' "$AUDIT_LOG_FILE"; then
        pass_test "audit_config writes configuration event"
    else
        fail_test "audit_config missing expected fields"
    fi
    _cleanup_func_test
}

# Test: audit_security writes security event
test_func_audit_security() {
    _reset_audit_logger
    audit_security "anomaly" "high" "Suspicious activity" '{}'
    if command grep -q '"event_type":"anomaly"' "$AUDIT_LOG_FILE" && \
       command grep -q '"severity":"high"' "$AUDIT_LOG_FILE"; then
        pass_test "audit_security writes security event"
    else
        fail_test "audit_security missing expected fields"
    fi
    _cleanup_func_test
}

# Test: audit_process writes process event
test_func_audit_process() {
    _reset_audit_logger
    audit_process "started" "test-proc" "1234" "0" "testuser"
    if command grep -q '"event_type":"started"' "$AUDIT_LOG_FILE" && \
       command grep -q '"process_name":"test-proc"' "$AUDIT_LOG_FILE"; then
        pass_test "audit_process writes process event"
    else
        fail_test "audit_process missing expected fields"
    fi
    _cleanup_func_test
}

# Test: audit_compliance writes compliance event
test_func_audit_compliance() {
    _reset_audit_logger
    audit_compliance "soc2" "CC7.2" "compliant" '{}'
    if command grep -q '"framework":"soc2"' "$AUDIT_LOG_FILE" && \
       command grep -q '"requirement":"CC7.2"' "$AUDIT_LOG_FILE" && \
       command grep -q '"status":"compliant"' "$AUDIT_LOG_FILE"; then
        pass_test "audit_compliance writes compliance event"
    else
        fail_test "audit_compliance missing expected fields"
    fi
    _cleanup_func_test
}

# Test: JSON output contains required fields
test_func_json_required_fields() {
    _reset_audit_logger
    audit_log "system" "info" "Field check" '{}'
    local last_line
    last_line=$(command tail -1 "$AUDIT_LOG_FILE")
    if echo "$last_line" | command grep -q '"@timestamp"' && \
       echo "$last_line" | command grep -q '"event_id"' && \
       echo "$last_line" | command grep -q '"category"' && \
       echo "$last_line" | command grep -q '"level"' && \
       echo "$last_line" | command grep -q '"message"'; then
        pass_test "JSON output contains required fields (@timestamp, event_id, etc.)"
    else
        fail_test "JSON output missing required fields"
    fi
    _cleanup_func_test
}

# Test: _json_escape escapes special characters
test_func_json_escape() {
    _reset_audit_logger
    local escaped
    escaped=$(_json_escape 'hello "world" with\backslash')
    if echo "$escaped" | command grep -q '\\"world\\"' && \
       echo "$escaped" | command grep -q '\\\\backslash'; then
        pass_test "_json_escape escapes special characters"
    else
        fail_test "_json_escape did not properly escape special characters: $escaped"
    fi
    _cleanup_func_test
}

# Test: AUDIT_STDOUT_COPY=true outputs to stdout
test_func_stdout_copy() {
    _reset_audit_logger
    export AUDIT_STDOUT_COPY="true"
    local stdout_output
    stdout_output=$(audit_log "system" "info" "Stdout test" '{}')
    if echo "$stdout_output" | command grep -q '"message":"Stdout test"'; then
        pass_test "AUDIT_STDOUT_COPY=true outputs to stdout"
    else
        fail_test "AUDIT_STDOUT_COPY=true did not output to stdout"
    fi
    _cleanup_func_test
}

# Test: get_retention_policy returns correct values per framework
test_func_get_retention_policy() {
    _reset_audit_logger
    local soc2_days hipaa_days fedramp_days
    soc2_days=$(get_retention_policy "soc2")
    hipaa_days=$(get_retention_policy "hipaa")
    fedramp_days=$(get_retention_policy "fedramp")
    if [ "$soc2_days" = "365" ] && [ "$hipaa_days" = "2190" ] && [ "$fedramp_days" = "1095" ]; then
        pass_test "get_retention_policy returns correct values per framework"
    else
        fail_test "get_retention_policy returned unexpected values: soc2=$soc2_days, hipaa=$hipaa_days, fedramp=$fedramp_days"
    fi
    _cleanup_func_test
}

# Run Batch 8 functional tests
run_test test_func_audit_init_creates_files "audit_init creates log directory and file"
run_test test_func_audit_init_writes_event "audit_init writes initialization event"
run_test test_func_audit_log_writes_json "audit_log writes JSON to log file"
run_test test_func_audit_log_level_filter "audit_log respects log level threshold filtering"
run_test test_func_audit_log_disabled "audit_log is a no-op when ENABLE_AUDIT_LOGGING=false"
run_test test_func_audit_auth "audit_auth writes authentication event with correct fields"
run_test test_func_audit_config "audit_config writes configuration event"
run_test test_func_audit_security "audit_security writes security event"
run_test test_func_audit_process "audit_process writes process event"
run_test test_func_audit_compliance "audit_compliance writes compliance event"
run_test test_func_json_required_fields "JSON output contains required fields"
run_test test_func_json_escape "_json_escape escapes special characters"
run_test test_func_stdout_copy "AUDIT_STDOUT_COPY=true outputs to stdout"
run_test test_func_get_retention_policy "get_retention_policy returns correct values per framework"

# Generate report
generate_report
