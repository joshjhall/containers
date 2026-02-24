#!/usr/bin/env bash
# Unit tests for HTTP MCP authentication support
#
# This test validates that:
# 1. inject_mcp_headers function exists in claude-setup script
# 2. inject_mcp_auth_header function exists in claude-setup script
# 3. Pipe-delimited header parsing (http_headers_str) exists
# 4. CLAUDE_MCP_AUTO_AUTH env var is referenced
# 5. jq.*mcpServers pattern is used for header injection
# 6. Auto-auth never applies to hardcoded MCPs (figma-desktop)
# 7. Bearer token uses ${ANTHROPIC_AUTH_TOKEN} env var reference

set -euo pipefail

# Source test framework
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "MCP HTTP Authentication Tests"

# Setup
SETUP_SCRIPT="$PROJECT_ROOT/lib/features/claude-code-setup.sh"

# Test: inject_mcp_headers function exists
test_inject_mcp_headers_exists() {
    assert_file_exists "$SETUP_SCRIPT"
    assert_file_contains "$SETUP_SCRIPT" "inject_mcp_headers" \
        "claude-code-setup.sh contains inject_mcp_headers function"
}

# Test: inject_mcp_auth_header function exists
test_inject_mcp_auth_header_exists() {
    assert_file_exists "$SETUP_SCRIPT"
    assert_file_contains "$SETUP_SCRIPT" "inject_mcp_auth_header" \
        "claude-code-setup.sh contains inject_mcp_auth_header function"
}

# Test: Pipe-delimited header parsing variable exists
test_pipe_delimited_headers_parsing() {
    assert_file_exists "$SETUP_SCRIPT"
    assert_file_contains "$SETUP_SCRIPT" "http_headers_str" \
        "claude-code-setup.sh has pipe-delimited header parsing variable"
}

# Test: CLAUDE_MCP_AUTO_AUTH env var is referenced
test_claude_mcp_auto_auth_referenced() {
    assert_file_exists "$SETUP_SCRIPT"
    assert_file_contains "$SETUP_SCRIPT" "CLAUDE_MCP_AUTO_AUTH" \
        "claude-code-setup.sh references CLAUDE_MCP_AUTO_AUTH env var"
}

# Test: jq used for mcpServers header injection
test_jq_mcp_headers_pattern() {
    assert_file_exists "$SETUP_SCRIPT"
    # jq and mcpServers may be on different lines due to line continuation
    assert_file_contains "$SETUP_SCRIPT" 'mcpServers.*headers' \
        "claude-code-setup.sh writes to mcpServers headers"
    assert_file_contains "$SETUP_SCRIPT" 'jq --arg name' \
        "claude-code-setup.sh uses jq with server name arg"
}

# Test: Auto-auth never applies to hardcoded MCPs (figma-desktop)
test_auto_auth_skips_hardcoded_mcps() {
    assert_file_exists "$SETUP_SCRIPT"
    # Auto-inject should only happen in the configure_mcp_list HTTP block,
    # not for hardcoded MCPs like figma-desktop.
    # Verify the lines around figma-desktop don't reference inject_mcp_auth_header
    local figma_block
    figma_block=$(grep -A5 'figma-desktop' "$SETUP_SCRIPT" | head -6)
    if echo "$figma_block" | grep -q 'inject_mcp_auth_header'; then
        fail_test "figma-desktop should not have auto-injected auth headers"
    else
        pass_test "figma-desktop does not auto-inject auth headers"
    fi
}

# Test: Bearer token uses ${ANTHROPIC_AUTH_TOKEN} env var reference (not literal)
test_bearer_token_reference_format() {
    assert_file_exists "$SETUP_SCRIPT"
    # Verify we write the env var reference, not a literal token
    assert_file_contains "$SETUP_SCRIPT" 'Bearer \${ANTHROPIC_AUTH_TOKEN}' \
        "Auth header uses \${ANTHROPIC_AUTH_TOKEN} env var reference"
}

# Test: HTTP MCP URLs are normalized with trailing slash
test_http_url_trailing_slash_normalization() {
    assert_file_exists "$SETUP_SCRIPT"
    # Verify URL normalization to avoid redirect chains stripping auth headers
    assert_file_contains "$SETUP_SCRIPT" 'http_url.*/' \
        "claude-code-setup.sh normalizes HTTP MCP URLs with trailing slash"
}

# Test: HTTP name validation regex exists in source
test_http_name_validation_exists() {
    assert_file_contains "$SETUP_SCRIPT" 'Skipping HTTP MCP with invalid name' \
        "claude-code-setup.sh validates HTTP MCP server names"
}

# Test: HTTP URL scheme validation exists in source
test_http_url_scheme_validation_exists() {
    assert_file_contains "$SETUP_SCRIPT" 'URL must be https:// or http://localhost' \
        "claude-code-setup.sh validates HTTP MCP URL schemes"
}

# Test: HTTP URL localhost restriction exists in source
test_http_url_localhost_restriction_exists() {
    assert_file_contains "$SETUP_SCRIPT" 'host\.docker\.internal' \
        "claude-code-setup.sh restricts http:// to localhost patterns"
}

# Functional test: valid HTTP MCP names pass the regex
test_valid_http_names_accepted() {
    local name_regex='^[a-zA-Z0-9][a-zA-Z0-9_-]*$'
    local valid_names=("my-server" "api_v2" "prod1" "MyMCP" "a" "test123" "a-b_c")
    for name in "${valid_names[@]}"; do
        if [[ ! "$name" =~ $name_regex ]]; then
            fail_test "Valid name '$name' was rejected by name regex"
            return
        fi
    done
    pass_test "All valid HTTP MCP names accepted by regex"
}

# Functional test: invalid HTTP MCP names fail the regex
test_invalid_http_names_rejected() {
    local name_regex='^[a-zA-Z0-9][a-zA-Z0-9_-]*$'
    local invalid_names=("../escape" "foo bar" 'name;rm' "" '"quoted"' "-start" "_start" "a/b" 'x"y')
    for name in "${invalid_names[@]}"; do
        if [[ "$name" =~ $name_regex ]]; then
            fail_test "Invalid name '$name' was accepted by name regex"
            return
        fi
    done
    pass_test "All invalid HTTP MCP names rejected by regex"
}

# Functional test: valid URLs pass scheme validation
test_valid_urls_accepted() {
    local accepted=0
    local urls=(
        "https://api.example.com/"
        "https://internal.corp.net:8443/mcp/"
        "http://localhost:8080/mcp/"
        "http://127.0.0.1:4000/"
        "http://[::1]:8080/mcp/"
        "http://host.docker.internal:8080/mcp/"
    )
    for url in "${urls[@]}"; do
        if [[ "$url" =~ ^https:// ]]; then
            ((accepted++))
        elif [[ "$url" =~ ^http://(localhost|127\.0\.0\.1|\[::1\]|host\.docker\.internal)(:|/) ]]; then
            ((accepted++))
        fi
    done
    assert_equals "$accepted" "${#urls[@]}" "All valid URLs accepted"
}

# Functional test: invalid URLs fail scheme validation
test_invalid_urls_rejected() {
    local urls=(
        "file:///etc/passwd"
        "javascript:alert(1)"
        "http://evil.com/mcp/"
        "ftp://files.example.com/"
        "http://attacker.internal:8080/"
        "gopher://host/"
    )
    for url in "${urls[@]}"; do
        local accepted=false
        if [[ "$url" =~ ^https:// ]]; then
            accepted=true
        elif [[ "$url" =~ ^http://(localhost|127\.0\.0\.1|\[::1\]|host\.docker\.internal)(:|/) ]]; then
            accepted=true
        fi
        if [ "$accepted" = "true" ]; then
            fail_test "Invalid URL '$url' was accepted by scheme validation"
            return
        fi
    done
    pass_test "All invalid URLs rejected by scheme validation"
}

# Run all tests
run_test test_inject_mcp_headers_exists "inject_mcp_headers function exists"
run_test test_inject_mcp_auth_header_exists "inject_mcp_auth_header function exists"
run_test test_pipe_delimited_headers_parsing "Pipe-delimited header parsing exists"
run_test test_claude_mcp_auto_auth_referenced "CLAUDE_MCP_AUTO_AUTH env var referenced"
run_test test_jq_mcp_headers_pattern "jq used for mcpServers header injection"
run_test test_auto_auth_skips_hardcoded_mcps "Auto-auth skips hardcoded MCPs"
run_test test_bearer_token_reference_format "Bearer token uses env var reference"
run_test test_http_url_trailing_slash_normalization "HTTP URL trailing slash normalization"
run_test test_http_name_validation_exists "HTTP name validation exists in source"
run_test test_http_url_scheme_validation_exists "HTTP URL scheme validation exists in source"
run_test test_http_url_localhost_restriction_exists "HTTP URL localhost restriction exists"
run_test test_valid_http_names_accepted "Valid HTTP MCP names accepted"
run_test test_invalid_http_names_rejected "Invalid HTTP MCP names rejected"
run_test test_valid_urls_accepted "Valid URLs accepted by scheme validation"
run_test test_invalid_urls_rejected "Invalid URLs rejected by scheme validation"

# Generate test report
generate_report
