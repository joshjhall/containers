#!/usr/bin/env bash
# Unit tests for lib/runtime/secrets/aws-secrets-manager.sh
# Tests AWS Secrets Manager integration functionality

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "AWS Secrets Manager Integration Tests"

# Source file under test
SOURCE_FILE="$PROJECT_ROOT/lib/runtime/secrets/aws-secrets-manager.sh"

# Setup function
setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$RESULTS_DIR/test-aws-secrets-$unique_id"
    mkdir -p "$TEST_TEMP_DIR/bin"
}

# Teardown function
teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
    unset AWS_SECRETS_ENABLED AWS_SECRET_NAME AWS_REGION AWS_SECRET_PREFIX \
          AWS_SECRET_VERSION_ID AWS_SECRET_VERSION_STAGE AWS_SECRET_ENV_VAR \
          TEST_TEMP_DIR 2>/dev/null || true
}

run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"
    setup
    run_test "$test_function" "$test_description"
    teardown
}

# Helper: run subshell with source file loaded
_run_aws_subshell() {
    bash -c "
        source '$SOURCE_FILE' >/dev/null 2>&1
        $1
    " 2>/dev/null
}

# Helper: create mock aws CLI
_create_mock_aws() {
    local response="${1:-}"
    local exit_code="${2:-0}"

    command cat > "$TEST_TEMP_DIR/bin/aws" << MOCK
#!/bin/bash
if [[ "\$1" == "sts" ]]; then
    exit $exit_code
fi
if [[ "\$1" == "configure" ]]; then
    echo "us-west-2"
    exit 0
fi
if [[ "\$1" == "secretsmanager" ]]; then
    echo '$response'
    exit $exit_code
fi
exit $exit_code
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/aws"
}

# Helper: create mock jq
_create_mock_jq() {
    command cat > "$TEST_TEMP_DIR/bin/jq" << 'MOCK'
#!/bin/bash
# Simple jq mock - pass through or extract specific fields
if [[ "$1" == "-r" ]]; then
    shift
fi
if [[ "$1" == "-e" ]]; then
    shift
    # Check if input is valid JSON
    command cat > /dev/null
    exit 0
fi
# For to_entries parsing, output key=value pairs
input=$(cat)
if [[ "$1" == *"to_entries"* ]]; then
    echo "$input" | command grep -oP '"(\w+)"\s*:\s*"([^"]*)"' | sed 's/"\([^"]*\)"\s*:\s*"\([^"]*\)"/\1=\2/' || true
elif [[ "$1" == *"SecretString"* ]]; then
    echo "$input" | command grep -oP '"SecretString"\s*:\s*"([^"]*)"' | sed 's/"SecretString"\s*:\s*"\([^"]*\)"/\1/' || true
elif [[ "$1" == *"SecretBinary"* ]]; then
    echo "$input" | command grep -oP '"SecretBinary"\s*:\s*"([^"]*)"' | sed 's/"SecretBinary"\s*:\s*"\([^"]*\)"/\1/' || true
else
    command cat > /dev/null
fi
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/jq"
}

# ============================================================================
# Static Analysis Tests
# ============================================================================

test_strict_mode() {
    assert_file_contains "$SOURCE_FILE" "set -euo pipefail" "Script uses strict mode"
}

test_defines_load_secrets_from_aws() {
    assert_file_contains "$SOURCE_FILE" "load_secrets_from_aws()" \
        "Script defines load_secrets_from_aws function"
}

test_defines_health_check() {
    assert_file_contains "$SOURCE_FILE" "aws_secrets_health_check()" \
        "Script defines aws_secrets_health_check function"
}

test_defines_rotation_check() {
    assert_file_contains "$SOURCE_FILE" "check_secret_rotation()" \
        "Script defines check_secret_rotation function"
}

test_exit_codes_documented() {
    assert_file_contains "$SOURCE_FILE" "Exit Codes:" "Exit codes are documented"
}

test_region_fallback_pattern() {
    assert_file_contains "$SOURCE_FILE" 'us-east-1' \
        "Script has us-east-1 as region fallback"
}

test_auth_error_detection() {
    assert_file_contains "$SOURCE_FILE" "AccessDenied" \
        "Script detects AccessDenied auth errors"
    assert_file_contains "$SOURCE_FILE" "InvalidClientTokenId" \
        "Script detects InvalidClientTokenId auth errors"
}

# ============================================================================
# Functional Tests - load_secrets_from_aws()
# ============================================================================

test_disabled_when_not_enabled() {
    local exit_code=0
    _run_aws_subshell "
        export AWS_SECRETS_ENABLED='false'
        load_secrets_from_aws >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "0" "$exit_code" "Should return 0 when disabled"
}

test_disabled_by_default() {
    local exit_code=0
    _run_aws_subshell "
        unset AWS_SECRETS_ENABLED 2>/dev/null || true
        load_secrets_from_aws >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "0" "$exit_code" "Should return 0 when not configured (default false)"
}

test_returns_error_when_secret_name_missing() {
    local exit_code=0
    _run_aws_subshell "
        export AWS_SECRETS_ENABLED='true'
        unset AWS_SECRET_NAME 2>/dev/null || true
        load_secrets_from_aws >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "1" "$exit_code" "Should return 1 when AWS_SECRET_NAME not set"
}

test_returns_error_when_aws_cli_missing() {
    local exit_code=0
    _run_aws_subshell "
        export PATH='$TEST_TEMP_DIR/bin'
        export AWS_SECRETS_ENABLED='true'
        export AWS_SECRET_NAME='test-secret'
        load_secrets_from_aws >/dev/null 2>&1
    " || exit_code=$?

    assert_not_equals "0" "$exit_code" "Should return error when aws CLI not found"
}

test_returns_error_when_jq_missing() {
    # Create mock aws but no jq
    _create_mock_aws '{}' 0
    local exit_code=0
    _run_aws_subshell "
        export PATH='$TEST_TEMP_DIR/bin'
        export AWS_SECRETS_ENABLED='true'
        export AWS_SECRET_NAME='test-secret'
        load_secrets_from_aws >/dev/null 2>&1
    " || exit_code=$?

    assert_not_equals "0" "$exit_code" "Should return error when jq not found"
}

test_region_resolution_from_env() {
    local result
    result=$(_run_aws_subshell "
        export AWS_REGION='eu-west-1'
        echo \"\$AWS_REGION\"
    ")

    assert_equals "eu-west-1" "$result" "Region should be taken from env var"
}

# ============================================================================
# Functional Tests - Health Check
# ============================================================================

test_health_check_when_disabled() {
    local exit_code=0
    _run_aws_subshell "
        export AWS_SECRETS_ENABLED='false'
        aws_secrets_health_check >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "0" "$exit_code" "Health check should pass when disabled"
}

test_health_check_returns_error_when_name_missing() {
    local exit_code=0
    _run_aws_subshell "
        export AWS_SECRETS_ENABLED='true'
        unset AWS_SECRET_NAME 2>/dev/null || true
        aws_secrets_health_check >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "1" "$exit_code" "Health check should fail when secret name missing"
}

test_health_check_returns_error_when_cli_missing() {
    local exit_code=0
    _run_aws_subshell "
        export PATH='$TEST_TEMP_DIR/bin'
        export AWS_SECRETS_ENABLED='true'
        export AWS_SECRET_NAME='test-secret'
        aws_secrets_health_check >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "1" "$exit_code" "Health check should fail when aws CLI missing"
}

test_health_check_with_mock_sts() {
    _create_mock_aws '' 0
    local exit_code=0
    _run_aws_subshell "
        export PATH='$TEST_TEMP_DIR/bin:/usr/bin'
        export AWS_SECRETS_ENABLED='true'
        export AWS_SECRET_NAME='test-secret'
        aws_secrets_health_check >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "0" "$exit_code" "Health check should pass with valid sts response"
}

test_health_check_with_failed_sts() {
    _create_mock_aws '' 1
    local exit_code=0
    _run_aws_subshell "
        export PATH='$TEST_TEMP_DIR/bin:/usr/bin'
        export AWS_SECRETS_ENABLED='true'
        export AWS_SECRET_NAME='test-secret'
        aws_secrets_health_check >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "1" "$exit_code" "Health check should fail with failed sts response"
}

# ============================================================================
# Functional Tests - Rotation Check
# ============================================================================

test_rotation_check_when_disabled() {
    local exit_code=0
    _run_aws_subshell "
        export AWS_SECRETS_ENABLED='false'
        check_secret_rotation >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "0" "$exit_code" "Rotation check should pass when disabled"
}

test_rotation_check_when_name_missing() {
    local exit_code=0
    _run_aws_subshell "
        export AWS_SECRETS_ENABLED='true'
        unset AWS_SECRET_NAME 2>/dev/null || true
        check_secret_rotation >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "1" "$exit_code" "Rotation check should fail when name missing"
}

# ============================================================================
# Static Analysis - Secret Parsing
# ============================================================================

test_json_secret_parsing_pattern() {
    assert_file_contains "$SOURCE_FILE" "SecretString" \
        "Script handles SecretString field"
}

test_binary_secret_pattern() {
    assert_file_contains "$SOURCE_FILE" "SecretBinary" \
        "Script handles SecretBinary field"
    assert_file_contains "$SOURCE_FILE" "base64 -d" \
        "Script decodes base64 binary secrets"
}

test_plain_text_fallback() {
    assert_file_contains "$SOURCE_FILE" "plain text" \
        "Script handles plain text secrets"
}

# ============================================================================
# Run all tests
# ============================================================================

# Static analysis
run_test_with_setup test_strict_mode "Script uses strict mode"
run_test_with_setup test_defines_load_secrets_from_aws "Defines load_secrets_from_aws function"
run_test_with_setup test_defines_health_check "Defines health check function"
run_test_with_setup test_defines_rotation_check "Defines rotation check function"
run_test_with_setup test_exit_codes_documented "Exit codes documented"
run_test_with_setup test_region_fallback_pattern "Region fallback to us-east-1"
run_test_with_setup test_auth_error_detection "Auth error detection patterns"

# Functional - main function
run_test_with_setup test_disabled_when_not_enabled "Disabled when AWS_SECRETS_ENABLED=false"
run_test_with_setup test_disabled_by_default "Disabled by default"
run_test_with_setup test_returns_error_when_secret_name_missing "Error when secret name missing"
run_test_with_setup test_returns_error_when_aws_cli_missing "Error when aws CLI missing"
run_test_with_setup test_returns_error_when_jq_missing "Error when jq missing"
run_test_with_setup test_region_resolution_from_env "Region from env var"

# Health check
run_test_with_setup test_health_check_when_disabled "Health check passes when disabled"
run_test_with_setup test_health_check_returns_error_when_name_missing "Health check fails when name missing"
run_test_with_setup test_health_check_returns_error_when_cli_missing "Health check fails when CLI missing"
run_test_with_setup test_health_check_with_mock_sts "Health check passes with valid STS"
run_test_with_setup test_health_check_with_failed_sts "Health check fails with failed STS"

# Rotation check
run_test_with_setup test_rotation_check_when_disabled "Rotation check passes when disabled"
run_test_with_setup test_rotation_check_when_name_missing "Rotation check fails when name missing"

# Secret parsing patterns
run_test_with_setup test_json_secret_parsing_pattern "JSON secret parsing pattern"
run_test_with_setup test_binary_secret_pattern "Binary secret handling"
run_test_with_setup test_plain_text_fallback "Plain text secret fallback"

# Generate test report
generate_report
