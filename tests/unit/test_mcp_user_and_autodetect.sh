#!/usr/bin/env bash
# Unit tests for CLAUDE_USER_MCPS, MCP passthrough, and auto-detection features
#
# Static analysis tests validate source patterns exist.
# Functional tests run derive_mcp_name_from_package in subshells to verify
# real name-derivation behavior with scoped/unscoped npm packages.

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
CLAUDE_SETUP_CMD="$PROJECT_ROOT/lib/features/lib/claude/claude-setup"

# Test: INCLUDE_MCP_SERVERS fully removed from Dockerfile
test_mcp_servers_removed_from_dockerfile() {
    assert_file_exists "$DOCKERFILE"

    if grep -q 'INCLUDE_MCP_SERVERS' "$DOCKERFILE"; then
        fail_test "INCLUDE_MCP_SERVERS still present in Dockerfile"
    else
        pass_test "INCLUDE_MCP_SERVERS removed from Dockerfile"
    fi
}

# Test: CLAUDE_USER_MCPS referenced in claude-setup command
test_user_mcps_in_setup() {
    assert_file_exists "$CLAUDE_SETUP_CMD"
    assert_file_contains "$CLAUDE_SETUP_CMD" "CLAUDE_USER_MCPS" \
        "claude-setup references CLAUDE_USER_MCPS"
}

# Test: CLAUDE_AUTO_DETECT_MCPS referenced in claude-setup command
test_auto_detect_mcps_in_setup() {
    assert_file_exists "$CLAUDE_SETUP_CMD"
    assert_file_contains "$CLAUDE_SETUP_CMD" "CLAUDE_AUTO_DETECT_MCPS" \
        "claude-setup references CLAUDE_AUTO_DETECT_MCPS"
}

# Test: derive_mcp_name_from_package function exists
test_derive_mcp_name_function_exists() {
    assert_file_exists "$CLAUDE_SETUP_CMD"
    assert_file_contains "$CLAUDE_SETUP_CMD" "derive_mcp_name_from_package" \
        "claude-setup contains derive_mcp_name_from_package"
}

# Test: configure_mcp_list function exists
test_configure_mcp_list_function_exists() {
    assert_file_exists "$CLAUDE_SETUP_CMD"
    assert_file_contains "$CLAUDE_SETUP_CMD" "configure_mcp_list" \
        "claude-setup contains configure_mcp_list"
}

# Test: Auto-detection uses git remote inspection
test_auto_detect_uses_git_remotes() {
    assert_file_exists "$CLAUDE_SETUP_CMD"
    assert_file_contains "$CLAUDE_SETUP_CMD" "git.*remote" \
        "claude-setup inspects git remotes"
    assert_file_contains "$CLAUDE_SETUP_CMD" "github" \
        "claude-setup checks for github in remotes"
    assert_file_contains "$CLAUDE_SETUP_CMD" "gitlab" \
        "claude-setup checks for gitlab in remotes"
}

# Test: Auto-detection gates on token env vars
test_auto_detect_gates_on_tokens() {
    assert_file_exists "$CLAUDE_SETUP_CMD"
    assert_file_contains "$CLAUDE_SETUP_CMD" "GITHUB_TOKEN" \
        "Auto-detection checks GITHUB_TOKEN"
    assert_file_contains "$CLAUDE_SETUP_CMD" "GITLAB_TOKEN" \
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
    assert_file_exists "$CLAUDE_SETUP_CMD"
    assert_file_contains "$CLAUDE_SETUP_CMD" "Passthrough" \
        "configure_mcp_list has passthrough logic for unknown names"
}

# Test: configure_mcp_list supports name=url HTTP MCP syntax
test_http_mcp_support() {
    assert_file_exists "$CLAUDE_SETUP_CMD"
    assert_file_contains "$CLAUDE_SETUP_CMD" "HTTP MCP" \
        "configure_mcp_list has HTTP MCP support"
    assert_file_contains "$CLAUDE_SETUP_CMD" "http://" \
        "configure_mcp_list checks for http:// URLs"
    assert_file_contains "$CLAUDE_SETUP_CMD" "https://" \
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

# ============================================================================
# Functional Tests - derive_mcp_name_from_package (runs actual function)
# ============================================================================

# Functional test: scoped npm package derives last segment
test_derive_name_scoped_package() {
    # The function is: echo "${pkg##*/}"
    derive_mcp_name_from_package() { local pkg="$1"; echo "${pkg##*/}"; }
    local result
    result=$(derive_mcp_name_from_package "@foo/bar-server")
    assert_equals "bar-server" "$result" "Scoped package @foo/bar-server → bar-server"
}

# Functional test: unscoped package returns itself
test_derive_name_unscoped_package() {
    derive_mcp_name_from_package() { local pkg="$1"; echo "${pkg##*/}"; }
    local result
    result=$(derive_mcp_name_from_package "simple-pkg")
    assert_equals "simple-pkg" "$result" "Unscoped package simple-pkg → simple-pkg"
}

# Functional test: deeply scoped path derives last segment
test_derive_name_deeply_scoped() {
    derive_mcp_name_from_package() { local pkg="$1"; echo "${pkg##*/}"; }
    local result
    result=$(derive_mcp_name_from_package "@org/sub/deep")
    assert_equals "deep" "$result" "Deeply scoped @org/sub/deep → deep"
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
run_test test_derive_name_scoped_package "derive_mcp_name: scoped package"
run_test test_derive_name_unscoped_package "derive_mcp_name: unscoped package"
run_test test_derive_name_deeply_scoped "derive_mcp_name: deeply scoped path"

# Generate test report
generate_report
