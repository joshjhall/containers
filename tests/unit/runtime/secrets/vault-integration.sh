#!/usr/bin/env bash
# Unit tests for lib/runtime/secrets/vault-integration.sh
# Tests HashiCorp Vault integration functionality

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Vault Integration Tests"

# Source file under test
SOURCE_FILE="$PROJECT_ROOT/lib/runtime/secrets/vault-integration.sh"

# Setup function - runs before each test
setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$RESULTS_DIR/test-vault-$unique_id"
    mkdir -p "$TEST_TEMP_DIR"
    mkdir -p "$TEST_TEMP_DIR/bin"
}

# Teardown function - runs after each test
teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
    unset VAULT_ENABLED VAULT_ADDR VAULT_TOKEN VAULT_SECRET_PATH VAULT_AUTH_METHOD \
          VAULT_ROLE_ID VAULT_SECRET_ID VAULT_K8S_ROLE VAULT_NAMESPACE \
          VAULT_SECRET_PREFIX TEST_TEMP_DIR 2>/dev/null || true
}

# Run tests with setup/teardown
run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"
    setup
    run_test "$test_function" "$test_description"
    teardown
}

# Helper: run subshell with source and suppress all log output
_run_vault_subshell() {
    bash -c "
        source '$SOURCE_FILE' >/dev/null 2>&1
        $1
    " 2>/dev/null
}

# ============================================================================
# Static Analysis Tests
# ============================================================================

test_strict_mode() {
    assert_file_contains "$SOURCE_FILE" "set -euo pipefail" "Script uses strict mode"
}

test_defines_vault_auth_token() {
    assert_file_contains "$SOURCE_FILE" "vault_auth_token()" \
        "Script defines vault_auth_token function"
}

test_defines_vault_auth_approle() {
    assert_file_contains "$SOURCE_FILE" "vault_auth_approle()" \
        "Script defines vault_auth_approle function"
}

test_defines_vault_auth_kubernetes() {
    assert_file_contains "$SOURCE_FILE" "vault_auth_kubernetes()" \
        "Script defines vault_auth_kubernetes function"
}

test_defines_load_secrets_from_vault() {
    assert_file_contains "$SOURCE_FILE" "load_secrets_from_vault()" \
        "Script defines load_secrets_from_vault function"
}

# ============================================================================
# Functional Tests - load_secrets_from_vault()
# ============================================================================

test_load_returns_0_when_disabled() {
    local exit_code=0
    _run_vault_subshell "
        export VAULT_ENABLED='false'
        load_secrets_from_vault >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "0" "$exit_code" "Should return 0 when VAULT_ENABLED is not true"
}

test_load_returns_1_when_vault_addr_not_set() {
    local exit_code=0
    _run_vault_subshell "
        export VAULT_ENABLED='true'
        unset VAULT_ADDR 2>/dev/null || true
        load_secrets_from_vault >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "1" "$exit_code" "Should return 1 when VAULT_ADDR not set"
}

test_load_returns_1_when_secret_path_not_set() {
    local exit_code=0
    _run_vault_subshell "
        export VAULT_ENABLED='true'
        export VAULT_ADDR='https://vault.example.com'
        unset VAULT_SECRET_PATH 2>/dev/null || true
        load_secrets_from_vault >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "1" "$exit_code" "Should return 1 when VAULT_SECRET_PATH not set"
}

test_load_returns_1_when_vault_cli_not_found() {
    local exit_code=0
    _run_vault_subshell "
        export VAULT_ENABLED='true'
        export VAULT_ADDR='https://vault.example.com'
        export VAULT_SECRET_PATH='secret/data/myapp'
        export PATH='/nonexistent-path-only'
        load_secrets_from_vault >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "1" "$exit_code" "Should return 1 when vault CLI not found"
}

test_load_returns_1_when_jq_not_found() {
    # Create a mock vault in PATH but do not provide jq
    cat > "$TEST_TEMP_DIR/bin/vault" << 'MOCK'
#!/bin/bash
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/vault"

    local exit_code=0
    _run_vault_subshell "
        export VAULT_ENABLED='true'
        export VAULT_ADDR='https://vault.example.com'
        export VAULT_SECRET_PATH='secret/data/myapp'
        export PATH='$TEST_TEMP_DIR/bin'
        load_secrets_from_vault >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "1" "$exit_code" "Should return 1 when jq not found"
}

test_load_returns_1_for_unknown_auth_method() {
    # Create mock vault and jq in PATH
    cat > "$TEST_TEMP_DIR/bin/vault" << 'MOCK'
#!/bin/bash
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/vault"

    cat > "$TEST_TEMP_DIR/bin/jq" << 'MOCK'
#!/bin/bash
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/jq"

    local exit_code=0
    _run_vault_subshell "
        export VAULT_ENABLED='true'
        export VAULT_ADDR='https://vault.example.com'
        export VAULT_SECRET_PATH='secret/data/myapp'
        export VAULT_AUTH_METHOD='invalid-method'
        export PATH='$TEST_TEMP_DIR/bin'
        load_secrets_from_vault >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "1" "$exit_code" "Should return 1 for unknown auth method"
}

test_load_dispatches_to_token_auth() {
    # Create mock vault that succeeds for token lookup and kv get
    cat > "$TEST_TEMP_DIR/bin/vault" << 'MOCK'
#!/bin/bash
case "$1" in
    token)
        if [[ "${2:-}" == "lookup" ]]; then exit 0; fi
        ;;
    kv)
        echo '{"data":{"data":{"TEST_KEY":"test_value"}}}'
        exit 0
        ;;
esac
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/vault"

    # Create a real jq pass-through (use system jq)
    cat > "$TEST_TEMP_DIR/bin/jq" << 'MOCK'
#!/bin/bash
exec /usr/bin/jq "$@"
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/jq"

    local exit_code=0
    _run_vault_subshell "
        export VAULT_ENABLED='true'
        export VAULT_ADDR='https://vault.example.com'
        export VAULT_SECRET_PATH='secret/data/myapp'
        export VAULT_AUTH_METHOD='token'
        export VAULT_TOKEN='mock-token-value'
        export PATH='$TEST_TEMP_DIR/bin:/usr/bin'
        load_secrets_from_vault >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "0" "$exit_code" "Token auth dispatch should succeed with valid mocks"
}

# ============================================================================
# Functional Tests - vault_auth_token()
# ============================================================================

test_auth_token_returns_2_when_token_not_set() {
    local exit_code=0
    _run_vault_subshell "
        unset VAULT_TOKEN 2>/dev/null || true
        vault_auth_token >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "2" "$exit_code" "Should return 2 when VAULT_TOKEN not set"
}

test_auth_token_returns_2_when_lookup_fails() {
    # Create mock vault that fails on token lookup
    cat > "$TEST_TEMP_DIR/bin/vault" << 'MOCK'
#!/bin/bash
case "$1" in
    token)
        if [[ "${2:-}" == "lookup" ]]; then exit 1; fi
        ;;
esac
exit 1
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/vault"

    local exit_code=0
    _run_vault_subshell "
        export VAULT_TOKEN='invalid-token'
        export PATH='$TEST_TEMP_DIR/bin'
        vault_auth_token >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "2" "$exit_code" "Should return 2 when vault token lookup fails"
}

test_auth_token_returns_0_when_lookup_succeeds() {
    # Create mock vault that succeeds on token lookup
    cat > "$TEST_TEMP_DIR/bin/vault" << 'MOCK'
#!/bin/bash
case "$1" in
    token)
        if [[ "${2:-}" == "lookup" ]]; then exit 0; fi
        ;;
esac
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/vault"

    local exit_code=0
    _run_vault_subshell "
        export VAULT_TOKEN='valid-mock-token'
        export PATH='$TEST_TEMP_DIR/bin:/usr/bin:/bin'
        vault_auth_token >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "0" "$exit_code" "Should return 0 when vault token lookup succeeds"
}

# ============================================================================
# Functional Tests - vault_auth_approle()
# ============================================================================

test_auth_approle_returns_2_when_role_id_missing() {
    local exit_code=0
    _run_vault_subshell "
        unset VAULT_ROLE_ID 2>/dev/null || true
        unset VAULT_SECRET_ID 2>/dev/null || true
        vault_auth_approle >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "2" "$exit_code" "Should return 2 when VAULT_ROLE_ID missing"
}

test_auth_approle_returns_2_when_vault_write_fails() {
    # Create mock vault that fails on write
    cat > "$TEST_TEMP_DIR/bin/vault" << 'MOCK'
#!/bin/bash
case "$1" in
    write)
        echo "Error: permission denied" >&2
        exit 1
        ;;
esac
exit 1
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/vault"

    local exit_code=0
    _run_vault_subshell "
        export VAULT_ROLE_ID='mock-role-id'
        export VAULT_SECRET_ID='mock-secret-id'
        export PATH='$TEST_TEMP_DIR/bin'
        vault_auth_approle >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "2" "$exit_code" "Should return 2 when vault write fails"
}

test_auth_approle_returns_0_with_valid_response() {
    # Create mock vault that returns a valid AppRole response
    cat > "$TEST_TEMP_DIR/bin/vault" << 'MOCK'
#!/bin/bash
case "$1" in
    write)
        echo '{"auth":{"client_token":"mock-client-token","accessor":"mock-accessor","policies":["default"]}}'
        exit 0
        ;;
esac
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/vault"

    # Use system jq for JSON parsing
    cat > "$TEST_TEMP_DIR/bin/jq" << 'MOCK'
#!/bin/bash
exec /usr/bin/jq "$@"
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/jq"

    local exit_code=0
    _run_vault_subshell "
        export VAULT_ROLE_ID='mock-role-id'
        export VAULT_SECRET_ID='mock-secret-id'
        export PATH='$TEST_TEMP_DIR/bin:/usr/bin'
        vault_auth_approle >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "0" "$exit_code" "Should return 0 with valid AppRole response containing client_token"
}

# ============================================================================
# Functional Tests - vault_auth_kubernetes()
# ============================================================================

test_auth_kubernetes_returns_2_when_role_missing() {
    local exit_code=0
    _run_vault_subshell "
        unset VAULT_K8S_ROLE 2>/dev/null || true
        vault_auth_kubernetes >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "2" "$exit_code" "Should return 2 when VAULT_K8S_ROLE missing"
}

test_auth_kubernetes_returns_2_when_jwt_file_not_found() {
    local exit_code=0
    _run_vault_subshell "
        export VAULT_K8S_ROLE='my-k8s-role'
        vault_auth_kubernetes >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "2" "$exit_code" "Should return 2 when JWT file not found"
}

# ============================================================================
# Functional Tests - vault_health_check()
# ============================================================================

test_health_check_returns_0_when_disabled() {
    local exit_code=0
    _run_vault_subshell "
        export VAULT_ENABLED='false'
        vault_health_check >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "0" "$exit_code" "Health check should return 0 when Vault disabled"
}

test_health_check_returns_1_when_addr_not_set() {
    local exit_code=0
    _run_vault_subshell "
        export VAULT_ENABLED='true'
        unset VAULT_ADDR 2>/dev/null || true
        vault_health_check >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "1" "$exit_code" "Health check should return 1 when VAULT_ADDR not set"
}

# ============================================================================
# Run all tests
# ============================================================================

# Static analysis
run_test_with_setup test_strict_mode "Script uses strict mode"
run_test_with_setup test_defines_vault_auth_token "Defines vault_auth_token function"
run_test_with_setup test_defines_vault_auth_approle "Defines vault_auth_approle function"
run_test_with_setup test_defines_vault_auth_kubernetes "Defines vault_auth_kubernetes function"
run_test_with_setup test_defines_load_secrets_from_vault "Defines load_secrets_from_vault function"

# load_secrets_from_vault
run_test_with_setup test_load_returns_0_when_disabled "Returns 0 when VAULT_ENABLED not true"
run_test_with_setup test_load_returns_1_when_vault_addr_not_set "Returns 1 when VAULT_ADDR not set"
run_test_with_setup test_load_returns_1_when_secret_path_not_set "Returns 1 when VAULT_SECRET_PATH not set"
run_test_with_setup test_load_returns_1_when_vault_cli_not_found "Returns 1 when vault CLI not found"
run_test_with_setup test_load_returns_1_when_jq_not_found "Returns 1 when jq not found"
run_test_with_setup test_load_returns_1_for_unknown_auth_method "Returns 1 for unknown auth method"
run_test_with_setup test_load_dispatches_to_token_auth "Dispatches to token auth and succeeds"

# vault_auth_token
run_test_with_setup test_auth_token_returns_2_when_token_not_set "Token auth returns 2 when VAULT_TOKEN not set"
run_test_with_setup test_auth_token_returns_2_when_lookup_fails "Token auth returns 2 when lookup fails"
run_test_with_setup test_auth_token_returns_0_when_lookup_succeeds "Token auth returns 0 when lookup succeeds"

# vault_auth_approle
run_test_with_setup test_auth_approle_returns_2_when_role_id_missing "AppRole auth returns 2 when VAULT_ROLE_ID missing"
run_test_with_setup test_auth_approle_returns_2_when_vault_write_fails "AppRole auth returns 2 when vault write fails"
run_test_with_setup test_auth_approle_returns_0_with_valid_response "AppRole auth returns 0 with valid response"

# vault_auth_kubernetes
run_test_with_setup test_auth_kubernetes_returns_2_when_role_missing "K8s auth returns 2 when VAULT_K8S_ROLE missing"
run_test_with_setup test_auth_kubernetes_returns_2_when_jwt_file_not_found "K8s auth returns 2 when JWT file not found"

# vault_health_check
run_test_with_setup test_health_check_returns_0_when_disabled "Health check returns 0 when disabled"
run_test_with_setup test_health_check_returns_1_when_addr_not_set "Health check returns 1 when VAULT_ADDR not set"

# Generate test report
generate_report
