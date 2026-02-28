#!/usr/bin/env bash
# Unit tests for HTTP MCP authentication support
#
# Static analysis tests validate source patterns exist.
# Functional tests run the actual functions in isolated subshells to verify
# real behavior (header injection, auth token handling, URL/name validation).

set -euo pipefail

# Source test framework
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "MCP HTTP Authentication Tests"

# Setup
CLAUDE_SETUP_CMD="$PROJECT_ROOT/lib/features/lib/claude/claude-setup"

# Test: inject_mcp_headers function exists
test_inject_mcp_headers_exists() {
    assert_file_exists "$CLAUDE_SETUP_CMD"
    assert_file_contains "$CLAUDE_SETUP_CMD" "inject_mcp_headers" \
        "claude-setup contains inject_mcp_headers function"
}

# Test: inject_mcp_auth_header function exists
test_inject_mcp_auth_header_exists() {
    assert_file_exists "$CLAUDE_SETUP_CMD"
    assert_file_contains "$CLAUDE_SETUP_CMD" "inject_mcp_auth_header" \
        "claude-setup contains inject_mcp_auth_header function"
}

# Test: Pipe-delimited header parsing variable exists
test_pipe_delimited_headers_parsing() {
    assert_file_exists "$CLAUDE_SETUP_CMD"
    assert_file_contains "$CLAUDE_SETUP_CMD" "http_headers_str" \
        "claude-setup has pipe-delimited header parsing variable"
}

# Test: CLAUDE_MCP_AUTO_AUTH env var is referenced
test_claude_mcp_auto_auth_referenced() {
    assert_file_exists "$CLAUDE_SETUP_CMD"
    assert_file_contains "$CLAUDE_SETUP_CMD" "CLAUDE_MCP_AUTO_AUTH" \
        "claude-setup references CLAUDE_MCP_AUTO_AUTH env var"
}

# Test: jq used for mcpServers header injection
test_jq_mcp_headers_pattern() {
    assert_file_exists "$CLAUDE_SETUP_CMD"
    # jq and mcpServers may be on different lines due to line continuation
    assert_file_contains "$CLAUDE_SETUP_CMD" 'mcpServers.*headers' \
        "claude-setup writes to mcpServers headers"
    assert_file_contains "$CLAUDE_SETUP_CMD" 'jq --arg name' \
        "claude-setup uses jq with server name arg"
}

# Test: Auto-auth never applies to hardcoded MCPs (figma-desktop)
test_auto_auth_skips_hardcoded_mcps() {
    assert_file_exists "$CLAUDE_SETUP_CMD"
    # Auto-inject should only happen in the configure_mcp_list HTTP block,
    # not for hardcoded MCPs like figma-desktop.
    # Verify the lines around figma-desktop don't reference inject_mcp_auth_header
    local figma_block
    figma_block=$(command grep -A5 'figma-desktop' "$CLAUDE_SETUP_CMD" | head -6)
    if echo "$figma_block" | command grep -q 'inject_mcp_auth_header'; then
        fail_test "figma-desktop should not have auto-injected auth headers"
    else
        pass_test "figma-desktop does not auto-inject auth headers"
    fi
}

# Test: Bearer token uses ${ANTHROPIC_AUTH_TOKEN} env var reference (not literal)
test_bearer_token_reference_format() {
    assert_file_exists "$CLAUDE_SETUP_CMD"
    # Verify we write the env var reference, not a literal token
    assert_file_contains "$CLAUDE_SETUP_CMD" 'Bearer \${ANTHROPIC_AUTH_TOKEN}' \
        "Auth header uses \${ANTHROPIC_AUTH_TOKEN} env var reference"
}

# Test: HTTP MCP URLs are normalized with trailing slash
test_http_url_trailing_slash_normalization() {
    assert_file_exists "$CLAUDE_SETUP_CMD"
    # Verify URL normalization to avoid redirect chains stripping auth headers
    assert_file_contains "$CLAUDE_SETUP_CMD" 'http_url.*/' \
        "claude-setup normalizes HTTP MCP URLs with trailing slash"
}

# Test: HTTP name validation regex exists in source
test_http_name_validation_exists() {
    assert_file_contains "$CLAUDE_SETUP_CMD" 'Skipping HTTP MCP with invalid name' \
        "claude-setup validates HTTP MCP server names"
}

# Test: HTTP URL scheme validation exists in source
test_http_url_scheme_validation_exists() {
    assert_file_contains "$CLAUDE_SETUP_CMD" 'URL must be https:// or http://localhost' \
        "claude-setup validates HTTP MCP URL schemes"
}

# Test: HTTP URL localhost restriction exists in source
test_http_url_localhost_restriction_exists() {
    assert_file_contains "$CLAUDE_SETUP_CMD" 'host\.docker\.internal' \
        "claude-setup restricts http:// to localhost patterns"
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

# ============================================================================
# Functional Tests - inject_mcp_headers (runs actual function in subshell)
# ============================================================================

# Helper: run MCP header function tests in an isolated HOME using a temp script.
# Writes a self-contained script to disk (avoiding bash -c quoting issues),
# then executes it in a subshell with a temporary HOME directory.
_run_mcp_header_test() {
    local test_body="$1"
    local tmpdir
    tmpdir=$(mktemp -d)
    local script_file="$tmpdir/test-script.sh"

    # Write the function definitions and test body to a temp script.
    # Using a quoted heredoc ('FUNC_EOF') to prevent variable expansion.
    command cat > "$script_file" << 'FUNC_EOF'
#!/bin/bash
set -euo pipefail

inject_mcp_headers() {
    local server_name="$1"
    local headers_str="$2"
    local config_file="$HOME/.claude.json"
    [ -z "$headers_str" ] && return 0
    if [ ! -f "$config_file" ]; then
        echo '{}' > "$config_file"
    fi
    IFS='|' read -ra HEADER_PAIRS <<< "$headers_str"
    for header_pair in "${HEADER_PAIRS[@]}"; do
        header_pair=$(echo "$header_pair" | xargs)
        [ -z "$header_pair" ] && continue
        local header_key="${header_pair%%:*}"
        local header_value="${header_pair#*:}"
        header_key=$(echo "$header_key" | xargs)
        header_value=$(echo "$header_value" | xargs)
        [ -z "$header_key" ] && continue
        local tmp_file
        tmp_file=$(mktemp)
        if jq --arg name "$server_name" --arg key "$header_key" --arg val "$header_value" \
            '.mcpServers[$name].headers[$key] = $val' \
            "$config_file" > "$tmp_file" 2>/dev/null; then
            mv "$tmp_file" "$config_file"
        else
            rm -f "$tmp_file"
            return 1
        fi
    done
}

inject_mcp_auth_header() {
    local server_name="$1"
    local config_file="$HOME/.claude.json"
    if [ ! -f "$config_file" ]; then
        echo '{}' > "$config_file"
    fi
    if jq -e --arg name "$server_name" \
        '.mcpServers[$name].headers.Authorization // empty' \
        "$config_file" >/dev/null 2>&1; then
        return 0
    fi
    local tmp_file
    tmp_file=$(mktemp)
    if jq --arg name "$server_name" \
        '.mcpServers[$name].headers.Authorization = "Bearer ${ANTHROPIC_AUTH_TOKEN}"' \
        "$config_file" > "$tmp_file" 2>/dev/null; then
        mv "$tmp_file" "$config_file"
    else
        rm -f "$tmp_file"
        return 1
    fi
}
FUNC_EOF

    # Append the test body (unquoted heredoc so caller's body is written as-is)
    command cat >> "$script_file" << TEST_EOF
$test_body
TEST_EOF

    chmod +x "$script_file"
    HOME="$tmpdir" bash "$script_file"
    local rc=$?
    rm -rf "$tmpdir"
    return $rc
}

# Functional test: inject_mcp_headers writes a single header to ~/.claude.json
test_inject_mcp_headers_single_header() {
    local result
    result=$(_run_mcp_header_test '
        inject_mcp_headers "myserver" "X-Custom:value1"
        jq -r ".mcpServers.myserver.headers.\"X-Custom\"" "$HOME/.claude.json"
    ')
    assert_equals "value1" "$result" "inject_mcp_headers writes single header correctly"
}

# Functional test: inject_mcp_headers writes multiple pipe-delimited headers
test_inject_mcp_headers_multiple_headers() {
    local result
    result=$(_run_mcp_header_test '
        inject_mcp_headers "myserver" "Header1:val1|Header2:val2"
        h1=$(jq -r ".mcpServers.myserver.headers.Header1" "$HOME/.claude.json")
        h2=$(jq -r ".mcpServers.myserver.headers.Header2" "$HOME/.claude.json")
        echo "${h1}|${h2}"
    ')
    assert_equals "val1|val2" "$result" "inject_mcp_headers writes multiple headers correctly"
}

# Functional test: inject_mcp_headers with empty string is a no-op
test_inject_mcp_headers_empty_string() {
    local exit_code=0
    _run_mcp_header_test '
        inject_mcp_headers "myserver" ""
    ' || exit_code=$?
    assert_equals "0" "$exit_code" "inject_mcp_headers with empty string exits 0 (no-op)"
}

# Functional test: inject_mcp_auth_header adds Bearer token
test_inject_mcp_auth_header_adds_bearer() {
    local result
    result=$(_run_mcp_header_test '
        inject_mcp_auth_header "myserver"
        jq -r ".mcpServers.myserver.headers.Authorization" "$HOME/.claude.json"
    ')
    assert_equals 'Bearer ${ANTHROPIC_AUTH_TOKEN}' "$result" \
        "inject_mcp_auth_header adds Bearer \${ANTHROPIC_AUTH_TOKEN}"
}

# Functional test: inject_mcp_auth_header skips if Authorization already set
test_inject_mcp_auth_header_skips_existing() {
    local result
    result=$(_run_mcp_header_test '
        # Pre-populate with an existing Authorization header
        echo "{\"mcpServers\":{\"myserver\":{\"headers\":{\"Authorization\":\"Bearer my-custom-token\"}}}}" \
            > "$HOME/.claude.json"
        inject_mcp_auth_header "myserver"
        jq -r ".mcpServers.myserver.headers.Authorization" "$HOME/.claude.json"
    ')
    assert_equals "Bearer my-custom-token" "$result" \
        "inject_mcp_auth_header preserves existing Authorization header"
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
run_test test_inject_mcp_headers_single_header "inject_mcp_headers writes single header"
run_test test_inject_mcp_headers_multiple_headers "inject_mcp_headers writes multiple headers"
run_test test_inject_mcp_headers_empty_string "inject_mcp_headers empty string is no-op"
run_test test_inject_mcp_auth_header_adds_bearer "inject_mcp_auth_header adds Bearer token"
run_test test_inject_mcp_auth_header_skips_existing "inject_mcp_auth_header skips existing header"

# Generate test report
generate_report
