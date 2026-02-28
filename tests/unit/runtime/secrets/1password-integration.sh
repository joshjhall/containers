#!/usr/bin/env bash
# Unit tests for lib/runtime/secrets/1password-integration.sh
# Tests 1Password integration functionality including Connect Server and CLI paths

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "1Password Integration Tests"

# Source file under test
SOURCE_FILE="$PROJECT_ROOT/lib/runtime/secrets/1password-integration.sh"

# Setup function - runs before each test
setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$RESULTS_DIR/test-1password-$unique_id"
    mkdir -p "$TEST_TEMP_DIR"
    mkdir -p "$TEST_TEMP_DIR/bin"
}

# Teardown function - runs after each test
teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
    unset OP_ENABLED OP_CONNECT_HOST OP_CONNECT_TOKEN OP_SERVICE_ACCOUNT_TOKEN \
          OP_VAULT OP_SECRET_PREFIX OP_ITEM_NAMES OP_SECRET_REFERENCES \
          TEST_TEMP_DIR 2>/dev/null || true
}

# Run tests with setup/teardown
run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"
    setup
    run_test "$test_function" "$test_description"
    teardown
}

# Helper: run commands in a subshell with source file loaded
# All log output is suppressed (sent to /dev/null), only the final echo result is captured
_run_op_subshell() {
    bash -c "
        source '$SOURCE_FILE' >/dev/null 2>&1
        $1
    " 2>/dev/null
}

# ============================================================================
# Static Analysis Tests
# ============================================================================

test_strict_mode() {
    assert_file_contains "$SOURCE_FILE" "set -euo pipefail" \
        "Script uses strict mode"
}

test_defines_op_connect_load_secrets() {
    assert_file_contains "$SOURCE_FILE" "op_connect_load_secrets()" \
        "Script defines op_connect_load_secrets function"
}

test_defines_op_cli_load_secrets() {
    assert_file_contains "$SOURCE_FILE" "op_cli_load_secrets()" \
        "Script defines op_cli_load_secrets function"
}

test_defines_load_secrets_from_1password() {
    assert_file_contains "$SOURCE_FILE" "load_secrets_from_1password()" \
        "Script defines load_secrets_from_1password function"
}

test_defines_op_health_check() {
    assert_file_contains "$SOURCE_FILE" "op_health_check()" \
        "Script defines op_health_check function"
}

test_sources_common_sh() {
    assert_file_contains "$SOURCE_FILE" 'common\.sh' \
        "Script sources common.sh for logging and helpers"
}

# ============================================================================
# Static Analysis Tests - Secret Leak Prevention
# ============================================================================

test_connect_item_search_no_log_leak() {
    # The Connect item search log_warning must NOT include $item (raw API response)
    local matches
    matches=$(command grep -c 'log_warning.*\$item[^_]' "$SOURCE_FILE" || true)

    assert_equals "0" "$matches" \
        "Connect item search should not log raw API response (\$item)"
}

test_connect_vault_list_no_log_leak() {
    # The Connect vault list log_error must NOT include $vaults (bare variable, not $vaults_*)
    local matches
    matches=$(command grep -cP 'log_error.*\$vaults\b' "$SOURCE_FILE" || true)

    assert_equals "0" "$matches" \
        "Connect vault list should not log raw vault response (\$vaults)"
}

test_cli_op_read_no_log_leak() {
    # The CLI op read log_warning must NOT include $value
    local matches
    matches=$(command grep -c 'log_warning.*\$value' "$SOURCE_FILE" || true)

    assert_equals "0" "$matches" \
        "CLI op read should not log secret value (\$value)"
}

test_cli_item_get_no_log_leak() {
    # The CLI item get log_warning must NOT include $item_json
    local matches
    matches=$(command grep -c 'log_warning.*\$item_json' "$SOURCE_FILE" || true)

    assert_equals "0" "$matches" \
        "CLI item get should not log item JSON (\$item_json)"
}

test_connect_item_search_uses_url_encode() {
    assert_file_contains "$SOURCE_FILE" 'url_encode' \
        "Connect item search should use url_encode for item names"
}

# ============================================================================
# Functional Tests - Secret Leak Prevention (Mock-based)
# ============================================================================

test_connect_error_log_no_body_leak() {
    # Mock curl to return a response with a "secret" body + non-200 status
    command cat > "$TEST_TEMP_DIR/bin/curl" << 'MOCK'
#!/bin/sh
# For health check, return 200
case "$*" in
    *"/health"*) echo "200"; exit 0 ;;
esac
# For vaults endpoint, return secret body with 403 status
printf '{"secret":"TOP_SECRET_VAULT_DATA"}\n403'
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/curl"

    # Mock jq to be available
    cp "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq" 2>/dev/null || {
        printf '#!/bin/sh\necho ""\n' > "$TEST_TEMP_DIR/bin/jq"
        chmod +x "$TEST_TEMP_DIR/bin/jq"
    }

    local log_output
    log_output=$(bash -c "
        export PATH='$TEST_TEMP_DIR/bin:/usr/bin'
        source '$SOURCE_FILE' 2>/dev/null
        export OP_CONNECT_HOST='http://localhost:8080'
        export OP_CONNECT_TOKEN='test-token'
        export OP_VAULT='MyVault'
        op_connect_load_secrets 2>&1
    " 2>&1 || true)

    # Verify the secret body text does NOT appear in log output
    local leak_count
    leak_count=$(echo "$log_output" | command grep -c 'TOP_SECRET_VAULT_DATA' || true)

    assert_equals "0" "$leak_count" \
        "Connect error log should not contain API response body"
}

test_cli_op_read_error_no_secret_leak() {
    # Mock op to output a secret value on stdout and fail
    command cat > "$TEST_TEMP_DIR/bin/op" << 'MOCK'
#!/bin/sh
case "$1" in
    account) exit 0 ;;
    read) echo "SUPER_SECRET_PASSWORD"; exit 1 ;;
esac
exit 1
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/op"

    local log_output
    log_output=$(bash -c "
        export PATH='$TEST_TEMP_DIR/bin:/usr/bin'
        source '$SOURCE_FILE' 2>/dev/null
        export OP_SERVICE_ACCOUNT_TOKEN='sa-token'
        export OP_SECRET_REFERENCES='op://vault/item/password'
        op_cli_load_secrets 2>&1
    " 2>&1 || true)

    local leak_count
    leak_count=$(echo "$log_output" | command grep -c 'SUPER_SECRET_PASSWORD' || true)

    assert_equals "0" "$leak_count" \
        "CLI op read error log should not contain secret value"
}

test_cli_item_get_error_no_json_leak() {
    # Mock op to output JSON with secret fields and fail
    command cat > "$TEST_TEMP_DIR/bin/op" << 'MOCK'
#!/bin/sh
case "$1" in
    account) exit 0 ;;
    item)
        echo '{"fields":[{"label":"password","value":"LEAKED_JSON_SECRET"}]}'
        exit 1
        ;;
esac
exit 1
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/op"

    local log_output
    log_output=$(bash -c "
        export PATH='$TEST_TEMP_DIR/bin:/usr/bin'
        source '$SOURCE_FILE' 2>/dev/null
        export OP_SERVICE_ACCOUNT_TOKEN='sa-token'
        export OP_ITEM_NAMES='my-item'
        op_cli_load_secrets 2>&1
    " 2>&1 || true)

    local leak_count
    leak_count=$(echo "$log_output" | command grep -c 'LEAKED_JSON_SECRET' || true)

    assert_equals "0" "$leak_count" \
        "CLI item get error log should not contain JSON field values"
}

# ============================================================================
# Functional Tests - load_secrets_from_1password()
# ============================================================================

test_load_secrets_disabled_by_default() {
    # OP_ENABLED is not set, should return 0 (disabled is not an error)
    local exit_code=0
    _run_op_subshell "
        unset OP_ENABLED 2>/dev/null || true
        load_secrets_from_1password >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "0" "$exit_code" \
        "Should return 0 when OP_ENABLED is not set (disabled)"
}

test_load_secrets_disabled_explicitly() {
    local exit_code=0
    _run_op_subshell "
        export OP_ENABLED='false'
        load_secrets_from_1password >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "0" "$exit_code" \
        "Should return 0 when OP_ENABLED is explicitly false"
}

test_load_secrets_both_methods_fail() {
    # Enable 1Password but provide no valid Connect or CLI config
    # Neither op_connect_load_secrets nor op_cli_load_secrets should succeed
    local exit_code=0
    _run_op_subshell "
        export OP_ENABLED='true'
        unset OP_CONNECT_HOST OP_CONNECT_TOKEN OP_SERVICE_ACCOUNT_TOKEN 2>/dev/null || true
        export PATH='$TEST_TEMP_DIR/bin'
        load_secrets_from_1password >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "3" "$exit_code" \
        "Should return 3 when both Connect and CLI methods fail"
}

test_load_secrets_connect_succeeds() {
    # Mock op_connect_load_secrets to succeed by overriding the function
    local exit_code=0
    _run_op_subshell "
        export OP_ENABLED='true'
        op_connect_load_secrets() { return 0; }
        load_secrets_from_1password >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "0" "$exit_code" \
        "Should return 0 when Connect method succeeds"
}

test_load_secrets_connect_fails_cli_fallback() {
    # Mock Connect to fail, CLI to succeed
    local exit_code=0
    _run_op_subshell "
        export OP_ENABLED='true'
        op_connect_load_secrets() { return 1; }
        op_cli_load_secrets() { return 0; }
        load_secrets_from_1password >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "0" "$exit_code" \
        "Should return 0 when Connect fails but CLI fallback succeeds"
}

# ============================================================================
# Functional Tests - op_connect_load_secrets()
# ============================================================================

test_connect_missing_host() {
    local exit_code=0
    _run_op_subshell "
        unset OP_CONNECT_HOST 2>/dev/null || true
        export OP_CONNECT_TOKEN='test-token'
        op_connect_load_secrets >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "1" "$exit_code" \
        "Should return 1 when OP_CONNECT_HOST is missing"
}

test_connect_missing_token() {
    local exit_code=0
    _run_op_subshell "
        export OP_CONNECT_HOST='http://localhost:8080'
        unset OP_CONNECT_TOKEN 2>/dev/null || true
        op_connect_load_secrets >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "1" "$exit_code" \
        "Should return 1 when OP_CONNECT_TOKEN is missing"
}

test_connect_curl_not_available() {
    # Set both host and token, but make curl unavailable via PATH manipulation
    local exit_code=0
    _run_op_subshell "
        export OP_CONNECT_HOST='http://localhost:8080'
        export OP_CONNECT_TOKEN='test-token'
        export PATH='$TEST_TEMP_DIR/bin'
        op_connect_load_secrets >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "1" "$exit_code" \
        "Should return 1 when curl is not available"
}

test_connect_jq_not_available() {
    # Create a mock curl but no jq
    printf '#!/bin/sh\nexit 0\n' > "$TEST_TEMP_DIR/bin/curl"
    chmod +x "$TEST_TEMP_DIR/bin/curl"

    local exit_code=0
    _run_op_subshell "
        export OP_CONNECT_HOST='http://localhost:8080'
        export OP_CONNECT_TOKEN='test-token'
        export PATH='$TEST_TEMP_DIR/bin'
        op_connect_load_secrets >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "1" "$exit_code" \
        "Should return 1 when jq is not available"
}

test_connect_field_name_normalization() {
    # Verify the source code uses normalize_env_var_name from common.sh
    assert_file_contains "$SOURCE_FILE" 'normalize_env_var_name' \
        "Source should use normalize_env_var_name for field label conversion"
}

# ============================================================================
# Functional Tests - op_cli_load_secrets()
# ============================================================================

test_cli_op_not_available() {
    local exit_code=0
    _run_op_subshell "
        export PATH='$TEST_TEMP_DIR/bin'
        op_cli_load_secrets >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "1" "$exit_code" \
        "Should return 1 when op CLI is not available"
}

test_cli_no_auth_no_session() {
    # Create a mock op that always fails (simulates not signed in)
    printf '#!/bin/sh\nexit 1\n' > "$TEST_TEMP_DIR/bin/op"
    chmod +x "$TEST_TEMP_DIR/bin/op"

    local exit_code=0
    _run_op_subshell "
        export PATH='$TEST_TEMP_DIR/bin'
        unset OP_SERVICE_ACCOUNT_TOKEN 2>/dev/null || true
        op_cli_load_secrets >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "2" "$exit_code" \
        "Should return 2 when no service account token and op not signed in"
}

test_cli_service_account_token_exported() {
    # Create a mock op that succeeds for account get
    printf '#!/bin/sh\nexit 0\n' > "$TEST_TEMP_DIR/bin/op"
    chmod +x "$TEST_TEMP_DIR/bin/op"

    local result
    result=$(_run_op_subshell "
        export PATH='$TEST_TEMP_DIR/bin:\$PATH'
        export OP_SERVICE_ACCOUNT_TOKEN='test-sa-token-123'
        op_cli_load_secrets >/dev/null 2>&1
        echo \"\${OP_SERVICE_ACCOUNT_TOKEN:-UNSET}\"
    ")

    assert_equals "test-sa-token-123" "$result" \
        "OP_SERVICE_ACCOUNT_TOKEN should remain exported after op_cli_load_secrets"
}

test_cli_secret_reference_field_extraction() {
    # Verify the source contains the field name extraction from op:// URI pattern
    # op://vault/item/field -> extracts "field" using awk -F'/'
    assert_file_contains "$SOURCE_FILE" "awk -F'/' '{print \$NF}'" \
        "Source should extract field name from op:// reference URI"
}

test_cli_jq_warning_when_unavailable() {
    # Verify the source code has a warning path when jq is not available
    assert_file_contains "$SOURCE_FILE" "jq not found, cannot parse item fields" \
        "Source should warn when jq is not available for item parsing"
}

# ============================================================================
# Functional Tests - op_health_check()
# ============================================================================

test_health_check_disabled() {
    local exit_code=0
    _run_op_subshell "
        unset OP_ENABLED 2>/dev/null || true
        op_health_check >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "0" "$exit_code" \
        "Health check should return 0 when OP_ENABLED is not true"
}

test_health_check_no_connect_no_cli() {
    local exit_code=0
    _run_op_subshell "
        export OP_ENABLED='true'
        unset OP_CONNECT_HOST OP_CONNECT_TOKEN 2>/dev/null || true
        export PATH='$TEST_TEMP_DIR/bin'
        op_health_check >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "1" "$exit_code" \
        "Health check should return 1 when neither Connect nor CLI is available"
}

test_health_check_connect_branch() {
    # Create a mock curl that returns 200 for health endpoint
    printf '#!/bin/sh\necho "200"\n' > "$TEST_TEMP_DIR/bin/curl"
    chmod +x "$TEST_TEMP_DIR/bin/curl"

    local exit_code=0
    _run_op_subshell "
        export OP_ENABLED='true'
        export OP_CONNECT_HOST='http://localhost:8080'
        export OP_CONNECT_TOKEN='test-token'
        export PATH='$TEST_TEMP_DIR/bin'
        op_health_check >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "0" "$exit_code" \
        "Health check should return 0 when Connect server health returns 200"
}

test_health_check_cli_branch() {
    # Create a mock op that succeeds for account get
    printf '#!/bin/sh\nexit 0\n' > "$TEST_TEMP_DIR/bin/op"
    chmod +x "$TEST_TEMP_DIR/bin/op"

    local exit_code=0
    _run_op_subshell "
        export OP_ENABLED='true'
        unset OP_CONNECT_HOST OP_CONNECT_TOKEN 2>/dev/null || true
        export PATH='$TEST_TEMP_DIR/bin'
        op_health_check >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "0" "$exit_code" \
        "Health check should return 0 when op CLI is authenticated"
}

# ============================================================================
# Run all tests
# ============================================================================

# Static analysis
run_test_with_setup test_strict_mode "Script uses strict mode"
run_test_with_setup test_defines_op_connect_load_secrets "Defines op_connect_load_secrets function"
run_test_with_setup test_defines_op_cli_load_secrets "Defines op_cli_load_secrets function"
run_test_with_setup test_defines_load_secrets_from_1password "Defines load_secrets_from_1password function"
run_test_with_setup test_defines_op_health_check "Defines op_health_check function"
run_test_with_setup test_sources_common_sh "Sources common.sh for logging and helpers"

# Secret leak prevention - static analysis
run_test_with_setup test_connect_item_search_no_log_leak "Connect item search does not log raw response"
run_test_with_setup test_connect_vault_list_no_log_leak "Connect vault list does not log raw response"
run_test_with_setup test_cli_op_read_no_log_leak "CLI op read does not log secret value"
run_test_with_setup test_cli_item_get_no_log_leak "CLI item get does not log item JSON"
run_test_with_setup test_connect_item_search_uses_url_encode "Connect item search uses url_encode"

# Secret leak prevention - functional
run_test_with_setup test_connect_error_log_no_body_leak "Connect error log does not leak response body"
run_test_with_setup test_cli_op_read_error_no_secret_leak "CLI op read error does not leak secret"
run_test_with_setup test_cli_item_get_error_no_json_leak "CLI item get error does not leak JSON fields"

# load_secrets_from_1password
run_test_with_setup test_load_secrets_disabled_by_default "Returns 0 when OP_ENABLED not set (disabled)"
run_test_with_setup test_load_secrets_disabled_explicitly "Returns 0 when OP_ENABLED is false"
run_test_with_setup test_load_secrets_both_methods_fail "Returns 3 when both Connect and CLI fail"
run_test_with_setup test_load_secrets_connect_succeeds "Returns 0 when Connect method succeeds"
run_test_with_setup test_load_secrets_connect_fails_cli_fallback "Connect fails, CLI fallback succeeds"

# op_connect_load_secrets
run_test_with_setup test_connect_missing_host "Connect returns 1 when OP_CONNECT_HOST missing"
run_test_with_setup test_connect_missing_token "Connect returns 1 when OP_CONNECT_TOKEN missing"
run_test_with_setup test_connect_curl_not_available "Connect returns 1 when curl not available"
run_test_with_setup test_connect_jq_not_available "Connect returns 1 when jq not available"
run_test_with_setup test_connect_field_name_normalization "Connect normalizes field labels to env var names"

# op_cli_load_secrets
run_test_with_setup test_cli_op_not_available "CLI returns 1 when op command not available"
run_test_with_setup test_cli_no_auth_no_session "CLI returns 2 when no token and not signed in"
run_test_with_setup test_cli_service_account_token_exported "CLI exports OP_SERVICE_ACCOUNT_TOKEN"
run_test_with_setup test_cli_secret_reference_field_extraction "CLI extracts field name from op:// URI"
run_test_with_setup test_cli_jq_warning_when_unavailable "CLI warns when jq not available"

# Health check
run_test_with_setup test_health_check_disabled "Health check returns 0 when disabled"
run_test_with_setup test_health_check_no_connect_no_cli "Health check returns 1 when no methods available"
run_test_with_setup test_health_check_connect_branch "Health check passes via Connect server"
run_test_with_setup test_health_check_cli_branch "Health check passes via CLI authentication"

# Generate test report
generate_report
