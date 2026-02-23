#!/usr/bin/env bash
# Unit tests for CLAUDE_USER_MCPS, MCP passthrough, and auto-detection features
#
# This test validates that:
# 1. INCLUDE_MCP_SERVERS is fully removed from the Dockerfile
# 2. CLAUDE_USER_MCPS is referenced in the claude-setup script
# 3. CLAUDE_AUTO_DETECT_MCPS is referenced in the claude-setup script
# 4. derive_mcp_name_from_package function exists in claude-setup
# 5. configure_mcp_list function exists in claude-setup
# 6. Auto-detection logic for GitHub/GitLab exists

set -euo pipefail

# Source test framework
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "MCP User MCPs and Auto-detect Tests"

# Setup
DOCKERFILE="$PROJECT_ROOT/Dockerfile"
SETUP_SCRIPT="$PROJECT_ROOT/lib/features/claude-code-setup.sh"

# Test: INCLUDE_MCP_SERVERS fully removed from Dockerfile
test_mcp_servers_removed_from_dockerfile() {
    assert_file_exists "$DOCKERFILE"

    if grep -q 'INCLUDE_MCP_SERVERS' "$DOCKERFILE"; then
        fail_test "INCLUDE_MCP_SERVERS still present in Dockerfile"
    else
        pass_test "INCLUDE_MCP_SERVERS removed from Dockerfile"
    fi
}

# Test: CLAUDE_USER_MCPS referenced in claude-setup script
test_user_mcps_in_setup() {
    assert_file_exists "$SETUP_SCRIPT"
    assert_file_contains "$SETUP_SCRIPT" "CLAUDE_USER_MCPS" \
        "claude-code-setup.sh references CLAUDE_USER_MCPS"
}

# Test: CLAUDE_AUTO_DETECT_MCPS referenced in claude-setup script
test_auto_detect_mcps_in_setup() {
    assert_file_exists "$SETUP_SCRIPT"
    assert_file_contains "$SETUP_SCRIPT" "CLAUDE_AUTO_DETECT_MCPS" \
        "claude-code-setup.sh references CLAUDE_AUTO_DETECT_MCPS"
}

# Test: derive_mcp_name_from_package function exists
test_derive_mcp_name_function_exists() {
    assert_file_exists "$SETUP_SCRIPT"
    assert_file_contains "$SETUP_SCRIPT" "derive_mcp_name_from_package" \
        "claude-code-setup.sh contains derive_mcp_name_from_package"
}

# Test: configure_mcp_list function exists
test_configure_mcp_list_function_exists() {
    assert_file_exists "$SETUP_SCRIPT"
    assert_file_contains "$SETUP_SCRIPT" "configure_mcp_list" \
        "claude-code-setup.sh contains configure_mcp_list"
}

# Test: Auto-detection uses git remote inspection
test_auto_detect_uses_git_remotes() {
    assert_file_exists "$SETUP_SCRIPT"
    assert_file_contains "$SETUP_SCRIPT" "git.*remote" \
        "claude-code-setup.sh inspects git remotes"
    assert_file_contains "$SETUP_SCRIPT" "github" \
        "claude-code-setup.sh checks for github in remotes"
    assert_file_contains "$SETUP_SCRIPT" "gitlab" \
        "claude-code-setup.sh checks for gitlab in remotes"
}

# Test: Auto-detection gates on token env vars
test_auto_detect_gates_on_tokens() {
    assert_file_exists "$SETUP_SCRIPT"
    assert_file_contains "$SETUP_SCRIPT" "GITHUB_TOKEN" \
        "Auto-detection checks GITHUB_TOKEN"
    assert_file_contains "$SETUP_SCRIPT" "GITLAB_TOKEN" \
        "Auto-detection checks GITLAB_TOKEN"
}

# Test: Unknown MCPs at build time show passthrough message (not "skipping")
test_unknown_mcp_build_time_passthrough() {
    assert_file_exists "$SETUP_SCRIPT"
    assert_file_contains "$SETUP_SCRIPT" "will be resolved at runtime via npx" \
        "Build-time unknown MCPs show passthrough message"
}

# Test: configure_mcp_list handles passthrough for unknown names
test_configure_mcp_list_passthrough_logic() {
    assert_file_exists "$SETUP_SCRIPT"
    assert_file_contains "$SETUP_SCRIPT" "Passthrough" \
        "configure_mcp_list has passthrough logic for unknown names"
}

# Test: configure_mcp_list supports name=url HTTP MCP syntax
test_http_mcp_support() {
    assert_file_exists "$SETUP_SCRIPT"
    assert_file_contains "$SETUP_SCRIPT" "HTTP MCP" \
        "configure_mcp_list has HTTP MCP support"
    assert_file_contains "$SETUP_SCRIPT" "http://" \
        "configure_mcp_list checks for http:// URLs"
    assert_file_contains "$SETUP_SCRIPT" "https://" \
        "configure_mcp_list checks for https:// URLs"
}

# Test: INCLUDE_MCP_SERVERS removed from docker-compose.yml
test_mcp_servers_removed_from_compose() {
    local compose_file="$PROJECT_ROOT/.devcontainer/docker-compose.yml"
    assert_file_exists "$compose_file"

    if grep -q 'INCLUDE_MCP_SERVERS' "$compose_file"; then
        fail_test "INCLUDE_MCP_SERVERS still present in docker-compose.yml"
    else
        pass_test "INCLUDE_MCP_SERVERS removed from docker-compose.yml"
    fi
}

# Run all tests
run_test test_mcp_servers_removed_from_dockerfile "INCLUDE_MCP_SERVERS removed from Dockerfile"
run_test test_user_mcps_in_setup "CLAUDE_USER_MCPS in claude-setup"
run_test test_auto_detect_mcps_in_setup "CLAUDE_AUTO_DETECT_MCPS in claude-setup"
run_test test_derive_mcp_name_function_exists "derive_mcp_name_from_package function exists"
run_test test_configure_mcp_list_function_exists "configure_mcp_list function exists"
run_test test_auto_detect_uses_git_remotes "Auto-detection uses git remotes"
run_test test_auto_detect_gates_on_tokens "Auto-detection gates on token env vars"
run_test test_unknown_mcp_build_time_passthrough "Unknown MCPs show passthrough message at build time"
run_test test_configure_mcp_list_passthrough_logic "configure_mcp_list has passthrough logic"
run_test test_http_mcp_support "configure_mcp_list supports HTTP MCP servers"
run_test test_mcp_servers_removed_from_compose "INCLUDE_MCP_SERVERS removed from docker-compose.yml"

# Generate test report
generate_report
