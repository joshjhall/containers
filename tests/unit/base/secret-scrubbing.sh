#!/usr/bin/env bash
# Unit tests for lib/base/secret-scrubbing.sh
# Tests secret scrubbing patterns for build log sanitization

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Secret Scrubbing Tests"

# Source file under test
SOURCE_FILE="$PROJECT_ROOT/lib/base/secret-scrubbing.sh"

# Setup function - runs before each test
setup() {
    # Reset include guard so we can re-source
    unset _SECRET_SCRUBBING_LOADED 2>/dev/null || true
    unset DISABLE_SECRET_SCRUBBING 2>/dev/null || true
    source "$SOURCE_FILE"
}

# Teardown function - runs after each test
teardown() {
    unset _SECRET_SCRUBBING_LOADED 2>/dev/null || true
    unset DISABLE_SECRET_SCRUBBING 2>/dev/null || true
}

# Run tests with setup/teardown
run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"
    setup
    run_test "$test_function" "$test_description"
    teardown
}

# ============================================================================
# Static Analysis Tests
# ============================================================================

test_strict_mode() {
    assert_contains "$(command cat "$SOURCE_FILE")" "set -euo pipefail" \
        "Script uses strict mode"
}

test_include_guard() {
    assert_contains "$(command cat "$SOURCE_FILE")" "_SECRET_SCRUBBING_LOADED" \
        "Script has include guard"
}

test_scrub_secrets_defined() {
    assert_contains "$(command cat "$SOURCE_FILE")" "scrub_secrets()" \
        "scrub_secrets function is defined"
}

test_scrub_url_defined() {
    assert_contains "$(command cat "$SOURCE_FILE")" "scrub_url()" \
        "scrub_url function is defined"
}

test_functions_exported() {
    local content
    content=$(command cat "$SOURCE_FILE")
    assert_contains "$content" "export -f scrub_secrets" \
        "scrub_secrets is exported"
    assert_contains "$content" "export -f scrub_url" \
        "scrub_url is exported"
}

# ============================================================================
# Bearer/Token/Basic Auth Header Tests
# ============================================================================

test_bearer_token_scrub() {
    local input="Authorization: Bearer fake-token-value"
    local result
    result=$(scrub_secrets "$input")
    assert_contains "$result" "***REDACTED***" \
        "Bearer token is scrubbed"
    assert_not_contains "$result" "fake-token-value" \
        "Original Bearer token is removed"
}

test_token_auth_scrub() {
    local input="Authorization: token ghp_xxxx"
    local result
    result=$(scrub_secrets "$input")
    assert_contains "$result" "***REDACTED***" \
        "Token auth is scrubbed"
    assert_not_contains "$result" "ghp_xxxx" \
        "Original token value is removed"
}

test_basic_auth_scrub() {
    local input="Authorization: Basic dGVzdDp0ZXN0"
    local result
    result=$(scrub_secrets "$input")
    assert_contains "$result" "***REDACTED***" \
        "Basic auth is scrubbed"
    assert_not_contains "$result" "dGVzdDp0ZXN0" \
        "Original Basic value is removed"
}

# ============================================================================
# GitHub Token Tests
# ============================================================================

test_ghp_token_scrub() {
    local input="Using token ghp_xxxxxxxxxxxxxxxxxxxx"
    local result
    result=$(scrub_secrets "$input")
    assert_contains "$result" "***GITHUB_TOKEN_REDACTED***" \
        "ghp_ token is scrubbed"
    assert_not_contains "$result" "ghp_xxxxxxxxxxxxxxxxxxxx" \
        "Original ghp_ token is removed"
}

test_github_pat_token_scrub() {
    local input="token=github_pat_xxxxxxxxxxxxxxxxxxxx"
    local result
    result=$(scrub_secrets "$input")
    assert_contains "$result" "***GITHUB_TOKEN_REDACTED***" \
        "github_pat_ token is scrubbed"
    assert_not_contains "$result" "github_pat_xxxxxxxxxxxxxxxxxxxx" \
        "Original github_pat_ token is removed"
}

test_gho_token_scrub() {
    local input="gho_xxxx"
    local result
    result=$(scrub_secrets "$input")
    assert_contains "$result" "***GITHUB_TOKEN_REDACTED***" \
        "gho_ token is scrubbed"
}

test_ghu_token_scrub() {
    local input="ghu_xxxx"
    local result
    result=$(scrub_secrets "$input")
    assert_contains "$result" "***GITHUB_TOKEN_REDACTED***" \
        "ghu_ token is scrubbed"
}

test_ghs_token_scrub() {
    local input="ghs_xxxx"
    local result
    result=$(scrub_secrets "$input")
    assert_contains "$result" "***GITHUB_TOKEN_REDACTED***" \
        "ghs_ token is scrubbed"
}

test_ghr_token_scrub() {
    local input="ghr_xxxx"
    local result
    result=$(scrub_secrets "$input")
    assert_contains "$result" "***GITHUB_TOKEN_REDACTED***" \
        "ghr_ token is scrubbed"
}

# ============================================================================
# API Key Tests (sk-/pk- prefix)
# ============================================================================

test_sk_api_key_scrub() {
    local input="key: sk-fake-xxxxxxxxxxxxxxxxxxxx"
    local result
    result=$(scrub_secrets "$input")
    assert_contains "$result" "***API_KEY_REDACTED***" \
        "sk- API key is scrubbed"
    assert_not_contains "$result" "sk-fake-xxxxxxxxxxxxxxxxxxxx" \
        "Original sk- key is removed"
}

test_pk_api_key_scrub() {
    local input="public key: pk-fake-xxxxxxxxxxxxxxxxxxxx"
    local result
    result=$(scrub_secrets "$input")
    assert_contains "$result" "***API_KEY_REDACTED***" \
        "pk- API key is scrubbed"
}

# ============================================================================
# password=/secret=/api_key= Pair Tests
# ============================================================================

test_password_pair_scrub() {
    local input="password=fakefake"
    local result
    result=$(scrub_secrets "$input")
    assert_contains "$result" "password=***REDACTED***" \
        "password= pair is scrubbed"
    assert_not_contains "$result" "fakefake" \
        "Original password value is removed"
}

test_secret_pair_scrub() {
    local input="secret=fakefake"
    local result
    result=$(scrub_secrets "$input")
    assert_contains "$result" "secret=***REDACTED***" \
        "secret= pair is scrubbed"
}

test_api_key_pair_scrub() {
    local input="api_key=fakefake"
    local result
    result=$(scrub_secrets "$input")
    assert_contains "$result" "api_key=***REDACTED***" \
        "api_key= pair is scrubbed"
}

test_uppercase_password_pair_scrub() {
    local input="PASSWORD=fakefake"
    local result
    result=$(scrub_secrets "$input")
    assert_contains "$result" "PASSWORD=***REDACTED***" \
        "PASSWORD= pair is scrubbed"
}

# ============================================================================
# URL with Embedded Credentials Tests
# ============================================================================

test_url_credentials_scrub() {
    local input="https://user:fake@github.com/repo.git"
    local result
    result=$(scrub_secrets "$input")
    assert_contains "$result" "***CREDENTIALS***@" \
        "URL credentials are scrubbed"
    assert_not_contains "$result" "user:fake" \
        "Original URL password is removed"
}

test_http_url_credentials_scrub() {
    local input="http://admin:fake@internal-host:8080/api"
    local result
    result=$(scrub_secrets "$input")
    assert_contains "$result" "***CREDENTIALS***@" \
        "HTTP URL credentials are scrubbed"
    assert_not_contains "$result" "admin:fake" \
        "Original URL credentials are removed"
}

test_scrub_url_function() {
    local result
    result=$(scrub_url "https://deploy:fake@registry.example.com/v2")
    assert_contains "$result" "***CREDENTIALS***@" \
        "scrub_url scrubs credentials"
    assert_not_contains "$result" "deploy:fake" \
        "scrub_url removes credentials"
}

# ============================================================================
# Known Env Var Assignment Tests
# ============================================================================

test_github_token_env_scrub() {
    local input="GITHUB_TOKEN=ghp_xxxx"
    local result
    result=$(scrub_secrets "$input")
    assert_contains "$result" "GITHUB_TOKEN=***REDACTED***" \
        "GITHUB_TOKEN= assignment is scrubbed"
}

test_aws_secret_env_scrub() {
    local input="AWS_SECRET_ACCESS_KEY=fakefakefake"
    local result
    result=$(scrub_secrets "$input")
    assert_contains "$result" "AWS_SECRET_ACCESS_KEY=***REDACTED***" \
        "AWS_SECRET_ACCESS_KEY= assignment is scrubbed"
}

test_anthropic_api_key_env_scrub() {
    local input="ANTHROPIC_API_KEY=fake-fake-fake"
    local result
    result=$(scrub_secrets "$input")
    assert_contains "$result" "ANTHROPIC_API_KEY=***REDACTED***" \
        "ANTHROPIC_API_KEY= assignment is scrubbed"
}

test_openai_api_key_env_scrub() {
    local input="OPENAI_API_KEY=fake-fake-fake"
    local result
    result=$(scrub_secrets "$input")
    assert_contains "$result" "OPENAI_API_KEY=***REDACTED***" \
        "OPENAI_API_KEY= assignment is scrubbed"
}

test_op_service_account_token_scrub() {
    local input="OP_SERVICE_ACCOUNT_TOKEN=fake-fake"
    local result
    result=$(scrub_secrets "$input")
    assert_contains "$result" "OP_SERVICE_ACCOUNT_TOKEN=***REDACTED***" \
        "OP_SERVICE_ACCOUNT_TOKEN= assignment is scrubbed"
}

# ============================================================================
# Edge Case Tests
# ============================================================================

test_no_secrets_passthrough() {
    local input="Installing Python 3.12.7 from source"
    local result
    result=$(scrub_secrets "$input")
    assert_equals "$input" "$result" \
        "Text without secrets passes through unchanged"
}

test_empty_string() {
    local result
    result=$(scrub_secrets "")
    assert_empty "$result" \
        "Empty string returns empty"
}

test_stdin_mode() {
    local result
    result=$(echo "GITHUB_TOKEN=ghp_xxxx" | scrub_secrets)
    assert_contains "$result" "GITHUB_TOKEN=***REDACTED***" \
        "Stdin mode scrubs secrets"
}

test_multiline_stdin() {
    local input
    input=$(printf "line1 normal\nGITHUB_TOKEN=ghp_xxxx\nline3 normal")
    local result
    result=$(echo "$input" | scrub_secrets)
    assert_contains "$result" "GITHUB_TOKEN=***REDACTED***" \
        "Multiline stdin scrubs secrets"
    assert_contains "$result" "line1 normal" \
        "Non-secret lines preserved in multiline"
    assert_contains "$result" "line3 normal" \
        "Trailing lines preserved in multiline"
}

test_multiple_secrets_one_line() {
    local input="GITHUB_TOKEN=ghp_xxxx password=fakefake"
    local result
    result=$(scrub_secrets "$input")
    assert_not_contains "$result" "ghp_xxxx" \
        "First secret on line is scrubbed"
    assert_not_contains "$result" "fakefake" \
        "Second secret on line is scrubbed"
}

test_partial_match_safety_tokenizer() {
    local input="Loading the tokenizer model"
    local result
    result=$(scrub_secrets "$input")
    assert_contains "$result" "tokenizer" \
        "Word 'tokenizer' is not false-positive scrubbed"
}

test_partial_match_safety_skeleton() {
    local input="Using skeleton template for project"
    local result
    result=$(scrub_secrets "$input")
    assert_contains "$result" "skeleton" \
        "Word 'skeleton' is not false-positive scrubbed"
}

# ============================================================================
# Opt-out Test
# ============================================================================

test_disable_scrubbing() {
    export DISABLE_SECRET_SCRUBBING=true
    local input="GITHUB_TOKEN=ghp_xxxx"
    local result
    result=$(scrub_secrets "$input")
    assert_equals "$input" "$result" \
        "DISABLE_SECRET_SCRUBBING=true bypasses scrubbing"
    unset DISABLE_SECRET_SCRUBBING
}

test_disable_scrubbing_url() {
    export DISABLE_SECRET_SCRUBBING=true
    local input="https://user:pass@host.com"
    local result
    result=$(scrub_url "$input")
    assert_equals "$input" "$result" \
        "DISABLE_SECRET_SCRUBBING=true bypasses URL scrubbing"
    unset DISABLE_SECRET_SCRUBBING
}

# ============================================================================
# Run all tests
# ============================================================================

# Static analysis tests
run_test test_strict_mode "Script uses strict mode"
run_test test_include_guard "Script has include guard"
run_test test_scrub_secrets_defined "scrub_secrets function is defined"
run_test test_scrub_url_defined "scrub_url function is defined"
run_test test_functions_exported "Functions are exported"

# Auth header tests
run_test_with_setup test_bearer_token_scrub "Bearer token is scrubbed"
run_test_with_setup test_token_auth_scrub "Token auth header is scrubbed"
run_test_with_setup test_basic_auth_scrub "Basic auth header is scrubbed"

# GitHub token tests
run_test_with_setup test_ghp_token_scrub "ghp_ token is scrubbed"
run_test_with_setup test_github_pat_token_scrub "github_pat_ token is scrubbed"
run_test_with_setup test_gho_token_scrub "gho_ token is scrubbed"
run_test_with_setup test_ghu_token_scrub "ghu_ token is scrubbed"
run_test_with_setup test_ghs_token_scrub "ghs_ token is scrubbed"
run_test_with_setup test_ghr_token_scrub "ghr_ token is scrubbed"

# API key tests
run_test_with_setup test_sk_api_key_scrub "sk- API key is scrubbed"
run_test_with_setup test_pk_api_key_scrub "pk- API key is scrubbed"

# Key=value pair tests
run_test_with_setup test_password_pair_scrub "password= pair is scrubbed"
run_test_with_setup test_secret_pair_scrub "secret= pair is scrubbed"
run_test_with_setup test_api_key_pair_scrub "api_key= pair is scrubbed"
run_test_with_setup test_uppercase_password_pair_scrub "PASSWORD= pair is scrubbed"

# URL credential tests
run_test_with_setup test_url_credentials_scrub "HTTPS URL credentials are scrubbed"
run_test_with_setup test_http_url_credentials_scrub "HTTP URL credentials are scrubbed"
run_test_with_setup test_scrub_url_function "scrub_url function works"

# Env var assignment tests
run_test_with_setup test_github_token_env_scrub "GITHUB_TOKEN= assignment is scrubbed"
run_test_with_setup test_aws_secret_env_scrub "AWS_SECRET_ACCESS_KEY= assignment is scrubbed"
run_test_with_setup test_anthropic_api_key_env_scrub "ANTHROPIC_API_KEY= assignment is scrubbed"
run_test_with_setup test_openai_api_key_env_scrub "OPENAI_API_KEY= assignment is scrubbed"
run_test_with_setup test_op_service_account_token_scrub "OP_SERVICE_ACCOUNT_TOKEN= assignment is scrubbed"

# Edge case tests
run_test_with_setup test_no_secrets_passthrough "Text without secrets passes through unchanged"
run_test_with_setup test_empty_string "Empty string returns empty"
run_test_with_setup test_stdin_mode "Stdin mode scrubs secrets"
run_test_with_setup test_multiline_stdin "Multiline stdin scrubs secrets"
run_test_with_setup test_multiple_secrets_one_line "Multiple secrets on one line are scrubbed"
run_test_with_setup test_partial_match_safety_tokenizer "Word tokenizer is not false-positive scrubbed"
run_test_with_setup test_partial_match_safety_skeleton "Word skeleton is not false-positive scrubbed"

# Opt-out tests
run_test_with_setup test_disable_scrubbing "DISABLE_SECRET_SCRUBBING bypasses scrubbing"
run_test_with_setup test_disable_scrubbing_url "DISABLE_SECRET_SCRUBBING bypasses URL scrubbing"

# Generate test report
generate_report
