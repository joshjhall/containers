#!/usr/bin/env bash
# Unit tests for MCP server registry
#
# This test validates that:
# 1. All registered MCP servers return valid npm packages
# 2. All registered MCP servers return valid add_args
# 3. Unknown server names are rejected
# 4. The registry list function returns all servers

set -euo pipefail

# Source test framework
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "MCP Server Registry Tests"

# Setup
REGISTRY_FILE="$PROJECT_ROOT/lib/features/lib/claude/mcp-registry.sh"

# Test: Registry file exists and is executable
test_registry_file_exists() {
    assert_file_exists "$REGISTRY_FILE"
    assert_executable "$REGISTRY_FILE"
}

# Test: All registered servers return npm packages
test_npm_packages() {
    source "$REGISTRY_FILE"

    local servers
    servers=$(mcp_registry_list)

    for server in $servers; do
        local package
        package=$(mcp_registry_get_npm_package "$server")
        assert_true [ -n "$package" ] "$server has npm package"
    done
}

# Test: Specific npm package mappings
test_npm_package_values() {
    source "$REGISTRY_FILE"

    local package
    package=$(mcp_registry_get_npm_package "brave-search")
    assert_equals "@modelcontextprotocol/server-brave-search" "$package" "brave-search npm package"

    package=$(mcp_registry_get_npm_package "fetch")
    assert_equals "@modelcontextprotocol/server-fetch" "$package" "fetch npm package"

    package=$(mcp_registry_get_npm_package "memory")
    assert_equals "@modelcontextprotocol/server-memory" "$package" "memory npm package"

    package=$(mcp_registry_get_npm_package "sequential-thinking")
    assert_equals "@modelcontextprotocol/server-sequential-thinking" "$package" "sequential-thinking npm package"

    package=$(mcp_registry_get_npm_package "git")
    assert_equals "@modelcontextprotocol/server-git" "$package" "git npm package"

    package=$(mcp_registry_get_npm_package "github")
    assert_equals "@modelcontextprotocol/server-github" "$package" "github npm package"

    package=$(mcp_registry_get_npm_package "gitlab")
    assert_equals "@modelcontextprotocol/server-gitlab" "$package" "gitlab npm package"

    package=$(mcp_registry_get_npm_package "sentry")
    assert_equals "@sentry/mcp-server" "$package" "sentry npm package"

    package=$(mcp_registry_get_npm_package "perplexity")
    assert_equals "@perplexity-ai/mcp-server" "$package" "perplexity npm package"

    package=$(mcp_registry_get_npm_package "kagi")
    assert_equals "kagimcp" "$package" "kagi package"
}

# Test: All registered servers return add args with correct structure
test_add_args() {
    source "$REGISTRY_FILE"

    local servers
    servers=$(mcp_registry_list)

    for server in $servers; do
        local args
        args=$(mcp_registry_get_add_args "$server")
        assert_not_empty "$args" "$server has add args"
        # All args should contain -t stdio
        assert_contains "$args" "-t stdio" "$server args include -t stdio"
        # Args should contain a package runner (npx -y for npm, uvx for Python)
        local pkg_type
        pkg_type=$(mcp_registry_get_package_type "$server")
        if [ "$pkg_type" = "uvx" ]; then
            assert_contains "$args" "uvx" "$server args include uvx"
        else
            assert_contains "$args" "npx -y" "$server args include npx -y"
        fi
    done
}

# Test: Servers requiring env vars have them documented in add_args
test_env_vars_in_args() {
    source "$REGISTRY_FILE"

    local args
    args=$(mcp_registry_get_add_args "brave-search")
    assert_contains "$args" "BRAVE_API_KEY" "brave-search args include env var"

    args=$(mcp_registry_get_add_args "sentry")
    assert_contains "$args" "SENTRY_ACCESS_TOKEN" "sentry args include env var"

    args=$(mcp_registry_get_add_args "perplexity")
    assert_contains "$args" "PERPLEXITY_API_KEY" "perplexity args include env var"

    args=$(mcp_registry_get_add_args "kagi")
    assert_contains "$args" "KAGI_API_KEY" "kagi args include env var"

    args=$(mcp_registry_get_add_args "github")
    assert_contains "$args" "GITHUB_PERSONAL_ACCESS_TOKEN" "github args include env var"

    args=$(mcp_registry_get_add_args "gitlab")
    assert_contains "$args" "GITLAB_PERSONAL_ACCESS_TOKEN" "gitlab args include env var"
}

# Test: Servers without required env vars have clean args
test_no_env_vars_when_not_needed() {
    source "$REGISTRY_FILE"

    local args
    args=$(mcp_registry_get_add_args "fetch")
    assert_not_contains "$args" "-e " "fetch args have no env vars"

    args=$(mcp_registry_get_add_args "sequential-thinking")
    assert_not_contains "$args" "-e " "sequential-thinking args have no env vars"

    args=$(mcp_registry_get_add_args "git")
    assert_not_contains "$args" "-e " "git args have no env vars"
}

# Test: env_docs returns correct values
test_env_docs() {
    source "$REGISTRY_FILE"

    local docs
    docs=$(mcp_registry_get_env_docs "brave-search")
    assert_equals "BRAVE_API_KEY" "$docs" "brave-search env docs"

    docs=$(mcp_registry_get_env_docs "sentry")
    assert_equals "SENTRY_ACCESS_TOKEN" "$docs" "sentry env docs"

    docs=$(mcp_registry_get_env_docs "fetch")
    assert_equals "" "$docs" "fetch has no required env vars"

    docs=$(mcp_registry_get_env_docs "sequential-thinking")
    assert_equals "" "$docs" "sequential-thinking has no required env vars"

    docs=$(mcp_registry_get_env_docs "kagi")
    assert_equals "KAGI_API_KEY" "$docs" "kagi env docs"

    docs=$(mcp_registry_get_env_docs "github")
    assert_equals "GITHUB_TOKEN" "$docs" "github env docs"
}

# Test: Unknown server name returns error
test_unknown_server_rejected() {
    source "$REGISTRY_FILE"

    if mcp_registry_get_npm_package "nonexistent-server" >/dev/null 2>&1; then
        fail_test "Unknown server should return error from get_npm_package"
    else
        pass_test "Unknown server rejected by get_npm_package"
    fi

    if mcp_registry_get_add_args "nonexistent-server" >/dev/null 2>&1; then
        fail_test "Unknown server should return error from get_add_args"
    else
        pass_test "Unknown server rejected by get_add_args"
    fi
}

# Test: is_registered correctly identifies servers
test_is_registered() {
    source "$REGISTRY_FILE"

    assert_true mcp_registry_is_registered "brave-search" "brave-search is registered"
    assert_true mcp_registry_is_registered "fetch" "fetch is registered"
    assert_true mcp_registry_is_registered "memory" "memory is registered"
    assert_true mcp_registry_is_registered "git" "git is registered"
    assert_true mcp_registry_is_registered "github" "github is registered"
    assert_true mcp_registry_is_registered "gitlab" "gitlab is registered"
    assert_true mcp_registry_is_registered "sentry" "sentry is registered"
    assert_true mcp_registry_is_registered "kagi" "kagi is registered"

    assert_false mcp_registry_is_registered "nonexistent" "nonexistent is not registered"
    assert_false mcp_registry_is_registered "" "empty string is not registered"
}

# Test: list function returns all servers
test_list_function() {
    source "$REGISTRY_FILE"

    local list
    list=$(mcp_registry_list)

    assert_contains "$list" "brave-search" "list includes brave-search"
    assert_contains "$list" "fetch" "list includes fetch"
    assert_contains "$list" "memory" "list includes memory"
    assert_contains "$list" "sequential-thinking" "list includes sequential-thinking"
    assert_contains "$list" "git" "list includes git"
    assert_contains "$list" "github" "list includes github"
    assert_contains "$list" "gitlab" "list includes gitlab"
    assert_contains "$list" "sentry" "list includes sentry"
    assert_contains "$list" "perplexity" "list includes perplexity"
    assert_contains "$list" "kagi" "list includes kagi"
}

# Test: Package type returns correct values
test_package_type() {
    source "$REGISTRY_FILE"

    local pkg_type
    pkg_type=$(mcp_registry_get_package_type "brave-search")
    assert_equals "npm" "$pkg_type" "brave-search is npm type"

    pkg_type=$(mcp_registry_get_package_type "fetch")
    assert_equals "npm" "$pkg_type" "fetch is npm type"

    pkg_type=$(mcp_registry_get_package_type "github")
    assert_equals "npm" "$pkg_type" "github is npm type"

    pkg_type=$(mcp_registry_get_package_type "gitlab")
    assert_equals "npm" "$pkg_type" "gitlab is npm type"

    pkg_type=$(mcp_registry_get_package_type "kagi")
    assert_equals "uvx" "$pkg_type" "kagi is uvx type"

    if mcp_registry_get_package_type "nonexistent" >/dev/null 2>&1; then
        fail_test "Unknown server should return error from get_package_type"
    else
        pass_test "Unknown server rejected by get_package_type"
    fi
}

# Test: Registry is referenced in claude-code-setup.sh and claude-setup
test_registry_used_in_setup() {
    local setup_file="$PROJECT_ROOT/lib/features/claude-code-setup.sh"
    local claude_setup_cmd="$PROJECT_ROOT/lib/features/lib/claude/claude-setup"
    assert_file_exists "$setup_file"
    assert_file_exists "$claude_setup_cmd"
    assert_file_contains "$setup_file" "mcp-registry.sh" "claude-code-setup.sh references mcp-registry.sh"
    assert_file_contains "$setup_file" "mcp_registry_is_registered" "claude-code-setup.sh uses registry validation"
    assert_file_contains "$claude_setup_cmd" "mcp_registry_get_add_args" "claude-setup uses registry add args"
}

# Run all tests
run_test test_registry_file_exists "Registry file exists and is executable"
run_test test_npm_packages "All registered servers return npm packages"
run_test test_npm_package_values "Specific npm package mappings are correct"
run_test test_add_args "All registered servers return add args with correct structure"
run_test test_env_vars_in_args "Servers with env vars include them in args"
run_test test_no_env_vars_when_not_needed "Servers without env vars have clean args"
run_test test_env_docs "Environment docs return correct values"
run_test test_unknown_server_rejected "Unknown server names are rejected"
run_test test_is_registered "is_registered correctly identifies servers"
run_test test_list_function "List function returns all servers"
run_test test_package_type "Package type returns correct values"
run_test test_registry_used_in_setup "Registry is referenced in claude-code-setup.sh"

# Generate test report
generate_report
