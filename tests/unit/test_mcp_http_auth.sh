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

# Run all tests
run_test test_inject_mcp_headers_exists "inject_mcp_headers function exists"
run_test test_inject_mcp_auth_header_exists "inject_mcp_auth_header function exists"
run_test test_pipe_delimited_headers_parsing "Pipe-delimited header parsing exists"
run_test test_claude_mcp_auto_auth_referenced "CLAUDE_MCP_AUTO_AUTH env var referenced"
run_test test_jq_mcp_headers_pattern "jq used for mcpServers header injection"
run_test test_auto_auth_skips_hardcoded_mcps "Auto-auth skips hardcoded MCPs"
run_test test_bearer_token_reference_format "Bearer token uses env var reference"
run_test test_http_url_trailing_slash_normalization "HTTP URL trailing slash normalization"

# Generate test report
generate_report
