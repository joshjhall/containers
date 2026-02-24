#!/bin/bash
# Unit tests for claude-code-setup.sh pattern matching functions
#
# Tests the extracted testable functions:
# - _match_plugin_in_list: Plugin detection from 'claude plugin list' output
# - _match_mcp_server_in_list: MCP server detection from 'claude mcp list' output
# - _parse_git_remote_host: Git remote URL parsing
# - _classify_git_host: Git platform classification from hostname
#
# These tests validate the pattern matching logic without requiring the Claude CLI.

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Claude Code Setup Pattern Matching Tests"

# ============================================================================
# Sample CLI Outputs (captured from real Claude CLI)
# ============================================================================

# Sample 'claude plugin list' output
SAMPLE_PLUGIN_LIST='  ❯ commit-commands@claude-plugins-official - Git commit helpers
  ❯ figma@claude-plugins-official - Figma design integration
  ❯ pr-review-toolkit@claude-plugins-official - PR review tools
  ❯ rust-analyzer-lsp@claude-plugins-official - Rust LSP integration
  ❯ pyright-lsp@claude-plugins-official - Python LSP integration'

# Empty plugin list
EMPTY_PLUGIN_LIST=''

# Plugin list with only whitespace
WHITESPACE_PLUGIN_LIST='

'

# Sample 'claude mcp list' output
SAMPLE_MCP_LIST='filesystem: npx -y @modelcontextprotocol/server-filesystem /workspace - running
github: npx -y @modelcontextprotocol/server-github - stopped
figma-desktop: http://host.docker.internal:3845/mcp - running
gitlab: npx -y @modelcontextprotocol/server-gitlab - running'

# Empty MCP list
EMPTY_MCP_LIST=''

# MCP list with different formats (edge cases)
MCP_LIST_EDGE_CASES='filesystem: /path/to/server - running
github-enterprise: npx server - stopped
my-custom-server: python server.py - running'

# ============================================================================
# Helper: Extract and define the pattern matching functions for testing
# ============================================================================

# These functions mirror the ones in claude-code-setup.sh
# We define them here to test without sourcing the full script

_match_plugin_in_list() {
    local plugin_name="$1"
    local list_output="$2"
    echo "$list_output" | grep -qE "^[[:space:]]*❯ ${plugin_name}@" 2>/dev/null
}

_match_mcp_server_in_list() {
    local server_name="$1"
    local list_output="$2"
    echo "$list_output" | grep -qE "^${server_name}:" 2>/dev/null
}

_parse_git_remote_host() {
    local remote_url="$1"
    local host=""

    [[ "$remote_url" =~ ^https?://([^/]+)/ ]] && host="${BASH_REMATCH[1]}"
    [[ -z "$host" && "$remote_url" =~ ^git@([^:]+): ]] && host="${BASH_REMATCH[1]}"
    [[ -z "$host" && "$remote_url" =~ ^ssh://[^@]+@([^/]+)/ ]] && host="${BASH_REMATCH[1]}"

    host="${host%%:*}"
    echo "$host"
}

_classify_git_host() {
    local host="$1"

    [[ -z "$host" ]] && { echo "none"; return; }
    [[ "$host" == "github.com" ]] && { echo "github"; return; }
    [[ "$host" == "gitlab.com" || "$host" == *"gitlab"* ]] && { echo "gitlab:$host"; return; }
    echo "unknown:$host"
}

# ============================================================================
# Plugin Matching Tests
# ============================================================================

test_plugin_match_exact_name() {
    if _match_plugin_in_list "figma" "$SAMPLE_PLUGIN_LIST"; then
        assert_true true "Matches 'figma' plugin"
    else
        assert_true false "Should match 'figma' plugin"
    fi
}

test_plugin_match_with_hyphen() {
    if _match_plugin_in_list "commit-commands" "$SAMPLE_PLUGIN_LIST"; then
        assert_true true "Matches 'commit-commands' plugin"
    else
        assert_true false "Should match 'commit-commands' plugin"
    fi
}

test_plugin_match_lsp_plugin() {
    if _match_plugin_in_list "rust-analyzer-lsp" "$SAMPLE_PLUGIN_LIST"; then
        assert_true true "Matches 'rust-analyzer-lsp' plugin"
    else
        assert_true false "Should match 'rust-analyzer-lsp' plugin"
    fi
}

test_plugin_no_match_nonexistent() {
    if _match_plugin_in_list "nonexistent-plugin" "$SAMPLE_PLUGIN_LIST"; then
        assert_true false "Should NOT match nonexistent plugin"
    else
        assert_true true "Correctly rejects nonexistent plugin"
    fi
}

test_plugin_no_match_partial_name() {
    # "fig" should NOT match "figma"
    if _match_plugin_in_list "fig" "$SAMPLE_PLUGIN_LIST"; then
        assert_true false "Should NOT match partial name 'fig'"
    else
        assert_true true "Correctly rejects partial name match"
    fi
}

test_plugin_no_match_suffix() {
    # "commands" should NOT match "commit-commands"
    if _match_plugin_in_list "commands" "$SAMPLE_PLUGIN_LIST"; then
        assert_true false "Should NOT match suffix 'commands'"
    else
        assert_true true "Correctly rejects suffix match"
    fi
}

test_plugin_empty_list() {
    if _match_plugin_in_list "figma" "$EMPTY_PLUGIN_LIST"; then
        assert_true false "Should NOT match in empty list"
    else
        assert_true true "Correctly handles empty list"
    fi
}

test_plugin_whitespace_list() {
    if _match_plugin_in_list "figma" "$WHITESPACE_PLUGIN_LIST"; then
        assert_true false "Should NOT match in whitespace-only list"
    else
        assert_true true "Correctly handles whitespace-only list"
    fi
}

test_plugin_case_sensitive() {
    # "Figma" should NOT match "figma" (case sensitive)
    if _match_plugin_in_list "Figma" "$SAMPLE_PLUGIN_LIST"; then
        assert_true false "Should NOT match different case"
    else
        assert_true true "Correctly rejects case mismatch"
    fi
}

# ============================================================================
# MCP Server Matching Tests
# ============================================================================

test_mcp_match_filesystem() {
    if _match_mcp_server_in_list "filesystem" "$SAMPLE_MCP_LIST"; then
        assert_true true "Matches 'filesystem' server"
    else
        assert_true false "Should match 'filesystem' server"
    fi
}

test_mcp_match_github() {
    if _match_mcp_server_in_list "github" "$SAMPLE_MCP_LIST"; then
        assert_true true "Matches 'github' server"
    else
        assert_true false "Should match 'github' server"
    fi
}

test_mcp_match_figma_desktop() {
    if _match_mcp_server_in_list "figma-desktop" "$SAMPLE_MCP_LIST"; then
        assert_true true "Matches 'figma-desktop' server"
    else
        assert_true false "Should match 'figma-desktop' server"
    fi
}

test_mcp_no_match_nonexistent() {
    if _match_mcp_server_in_list "nonexistent" "$SAMPLE_MCP_LIST"; then
        assert_true false "Should NOT match nonexistent server"
    else
        assert_true true "Correctly rejects nonexistent server"
    fi
}

test_mcp_no_match_partial() {
    # "file" should NOT match "filesystem"
    if _match_mcp_server_in_list "file" "$SAMPLE_MCP_LIST"; then
        assert_true false "Should NOT match partial name 'file'"
    else
        assert_true true "Correctly rejects partial name"
    fi
}

test_mcp_no_match_contains() {
    # "system" should NOT match "filesystem"
    if _match_mcp_server_in_list "system" "$SAMPLE_MCP_LIST"; then
        assert_true false "Should NOT match substring 'system'"
    else
        assert_true true "Correctly rejects substring match"
    fi
}

test_mcp_no_match_similar_prefix() {
    # "github" should NOT match "github-enterprise" (from edge cases)
    if _match_mcp_server_in_list "github" "$MCP_LIST_EDGE_CASES"; then
        assert_true false "Should NOT match 'github' when 'github-enterprise' exists"
    else
        assert_true true "Correctly distinguishes 'github' from 'github-enterprise'"
    fi
}

test_mcp_match_with_hyphen_prefix() {
    # "github-enterprise" should match exactly
    if _match_mcp_server_in_list "github-enterprise" "$MCP_LIST_EDGE_CASES"; then
        assert_true true "Matches 'github-enterprise' exactly"
    else
        assert_true false "Should match 'github-enterprise'"
    fi
}

test_mcp_empty_list() {
    if _match_mcp_server_in_list "filesystem" "$EMPTY_MCP_LIST"; then
        assert_true false "Should NOT match in empty list"
    else
        assert_true true "Correctly handles empty list"
    fi
}

# ============================================================================
# Git Remote URL Parsing Tests
# ============================================================================

test_parse_https_github() {
    local result
    result=$(_parse_git_remote_host "https://github.com/user/repo.git")
    assert_equals "$result" "github.com" "Parse HTTPS GitHub URL"
}

test_parse_https_gitlab() {
    local result
    result=$(_parse_git_remote_host "https://gitlab.com/user/repo.git")
    assert_equals "$result" "gitlab.com" "Parse HTTPS GitLab URL"
}

test_parse_https_self_hosted() {
    local result
    result=$(_parse_git_remote_host "https://git.company.com/user/repo.git")
    assert_equals "$result" "git.company.com" "Parse HTTPS self-hosted URL"
}

test_parse_ssh_shorthand_github() {
    local result
    result=$(_parse_git_remote_host "git@github.com:user/repo.git")
    assert_equals "$result" "github.com" "Parse SSH shorthand GitHub URL"
}

test_parse_ssh_shorthand_gitlab() {
    local result
    result=$(_parse_git_remote_host "git@gitlab.com:user/repo.git")
    assert_equals "$result" "gitlab.com" "Parse SSH shorthand GitLab URL"
}

test_parse_ssh_shorthand_self_hosted() {
    local result
    result=$(_parse_git_remote_host "git@git.company.com:group/repo.git")
    assert_equals "$result" "git.company.com" "Parse SSH shorthand self-hosted URL"
}

test_parse_ssh_url_github() {
    local result
    result=$(_parse_git_remote_host "ssh://git@github.com/user/repo.git")
    assert_equals "$result" "github.com" "Parse SSH URL GitHub"
}

test_parse_ssh_url_with_port() {
    local result
    result=$(_parse_git_remote_host "ssh://git@gitlab.company.com:2222/user/repo.git")
    # Port should be stripped
    assert_equals "$result" "gitlab.company.com" "Parse SSH URL with port"
}

test_parse_https_with_port() {
    local result
    result=$(_parse_git_remote_host "https://github.com:443/user/repo.git")
    assert_equals "$result" "github.com" "Parse HTTPS URL with port"
}

test_parse_empty_url() {
    local result
    result=$(_parse_git_remote_host "")
    assert_equals "$result" "" "Handle empty URL"
}

test_parse_invalid_url() {
    local result
    result=$(_parse_git_remote_host "not-a-valid-url")
    assert_equals "$result" "" "Handle invalid URL"
}

test_parse_http_url() {
    local result
    result=$(_parse_git_remote_host "http://github.com/user/repo.git")
    assert_equals "$result" "github.com" "Parse HTTP URL"
}

# ============================================================================
# Git Platform Classification Tests
# ============================================================================

test_classify_github() {
    local result
    result=$(_classify_git_host "github.com")
    assert_equals "$result" "github" "Classify github.com"
}

test_classify_gitlab() {
    local result
    result=$(_classify_git_host "gitlab.com")
    assert_equals "$result" "gitlab:gitlab.com" "Classify gitlab.com"
}

test_classify_self_hosted_gitlab() {
    local result
    result=$(_classify_git_host "gitlab.company.com")
    assert_equals "$result" "gitlab:gitlab.company.com" "Classify self-hosted GitLab"
}

test_classify_gitlab_subdomain() {
    local result
    result=$(_classify_git_host "code.gitlab.company.com")
    assert_equals "$result" "gitlab:code.gitlab.company.com" "Classify GitLab subdomain"
}

test_classify_unknown() {
    local result
    result=$(_classify_git_host "bitbucket.org")
    assert_equals "$result" "unknown:bitbucket.org" "Classify unknown host"
}

test_classify_self_hosted_git() {
    local result
    result=$(_classify_git_host "git.company.com")
    assert_equals "$result" "unknown:git.company.com" "Classify self-hosted git"
}

test_classify_empty() {
    local result
    result=$(_classify_git_host "")
    assert_equals "$result" "none" "Classify empty host"
}

# ============================================================================
# Edge Cases and Regression Tests
# ============================================================================

test_plugin_special_characters_in_name() {
    # Plugin names with numbers
    local list='  ❯ context7@claude-plugins-official - Context provider'
    if _match_plugin_in_list "context7" "$list"; then
        assert_true true "Matches plugin with number in name"
    else
        assert_true false "Should match plugin with number"
    fi
}

test_mcp_server_with_numbers() {
    local list='server1: command - running
server-v2: command - running'
    if _match_mcp_server_in_list "server1" "$list"; then
        assert_true true "Matches server with number"
    else
        assert_true false "Should match server with number"
    fi
}

test_mcp_no_false_positive_on_description() {
    # "filesystem" appears in the command, but we should only match at line start
    local list='other-server: npx filesystem-helper - running'
    if _match_mcp_server_in_list "filesystem" "$list"; then
        assert_true false "Should NOT match 'filesystem' in command args"
    else
        assert_true true "Correctly ignores 'filesystem' in command args"
    fi
}

test_plugin_marketplace_variation() {
    # Test with different marketplace names in the output
    local list='  ❯ figma@other-marketplace - Figma design'
    if _match_plugin_in_list "figma" "$list"; then
        assert_true true "Matches regardless of marketplace"
    else
        assert_true false "Should match regardless of marketplace name"
    fi
}

# ============================================================================
# CLAUDE_CHANNEL Validation Tests
# ============================================================================

# Path to the source file under test
CLAUDE_CODE_SETUP_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../lib/features" && pwd)/claude-code-setup.sh"

# Helper: test whether a channel value matches the allowlist pattern
_is_valid_channel() {
    local channel="$1"
    case "$channel" in
        latest|stable) return 0 ;;
        *) return 1 ;;
    esac
}

test_channel_validation_exists() {
    # Static check: the source file must contain the case guard
    if grep -q 'Invalid CLAUDE_CHANNEL' "$CLAUDE_CODE_SETUP_SRC"; then
        pass_test "Source contains CLAUDE_CHANNEL validation guard"
    else
        fail_test "Source is missing CLAUDE_CHANNEL validation guard"
    fi
}

test_valid_channels_accepted() {
    local failures=0
    for ch in "latest" "stable"; do
        if ! _is_valid_channel "$ch"; then
            failures=$((failures + 1))
        fi
    done
    assert_equals "$failures" "0" "Both 'latest' and 'stable' accepted"
}

test_invalid_channels_rejected() {
    local adversarial_values=(
        'latest; echo INJECTED'
        'stable && rm -rf /'
        'beta'
        ''
        '../../etc/passwd'
        'latest$(whoami)'
    )
    local failures=0
    for ch in "${adversarial_values[@]}"; do
        if _is_valid_channel "$ch"; then
            failures=$((failures + 1))
        fi
    done
    assert_equals "$failures" "0" "All adversarial channel values rejected"
}

# ============================================================================
# MCP Passthrough npm Package Name Validation Tests
# ============================================================================

# Helper: test whether a package name matches the npm validation regex
_is_valid_npm_package_name() {
    local name="$1"
    [[ "$name" =~ ^[@a-zA-Z0-9][-a-zA-Z0-9_./@]*$ ]]
}

test_mcp_passthrough_validation_exists() {
    # Static check: the source file must contain the npm package name regex guard
    if grep -q '\^[@a-zA-Z0-9\]' "$CLAUDE_CODE_SETUP_SRC"; then
        pass_test "Source contains npm package name validation guard"
    else
        fail_test "Source is missing npm package name validation guard"
    fi
}

test_valid_npm_names_accepted() {
    local valid_names=(
        "@modelcontextprotocol/server-fetch"
        "my-server"
        "@org/pkg"
        "@sentry/mcp-server"
        "some_package.v2"
    )
    local failures=0
    for name in "${valid_names[@]}"; do
        if ! _is_valid_npm_package_name "$name"; then
            echo "  FAIL: '$name' should be accepted" >&2
            failures=$((failures + 1))
        fi
    done
    assert_equals "$failures" "0" "All valid npm package names accepted"
}

test_invalid_npm_names_rejected() {
    local adversarial_values=(
        "'; rm -rf /'"
        '$(whoami)'
        ""
        '`id`'
        "; echo pwned"
        '| cat /etc/passwd'
    )
    local failures=0
    for name in "${adversarial_values[@]}"; do
        if _is_valid_npm_package_name "$name"; then
            echo "  FAIL: '$name' should be rejected" >&2
            failures=$((failures + 1))
        fi
    done
    assert_equals "$failures" "0" "All adversarial npm package names rejected"
}

# ============================================================================
# Run Tests
# ============================================================================

# CLAUDE_CHANNEL validation tests
run_test test_channel_validation_exists "Channel: Validation guard exists in source"
run_test test_valid_channels_accepted "Channel: Valid values accepted"
run_test test_invalid_channels_rejected "Channel: Adversarial values rejected"

# MCP passthrough npm package name validation tests
run_test test_mcp_passthrough_validation_exists "MCP passthrough: Validation guard exists in source"
run_test test_valid_npm_names_accepted "MCP passthrough: Valid npm names accepted"
run_test test_invalid_npm_names_rejected "MCP passthrough: Adversarial npm names rejected"

# Plugin matching tests
run_test test_plugin_match_exact_name "Plugin: Match exact name"
run_test test_plugin_match_with_hyphen "Plugin: Match name with hyphen"
run_test test_plugin_match_lsp_plugin "Plugin: Match LSP plugin"
run_test test_plugin_no_match_nonexistent "Plugin: No match for nonexistent"
run_test test_plugin_no_match_partial_name "Plugin: No match for partial name"
run_test test_plugin_no_match_suffix "Plugin: No match for suffix"
run_test test_plugin_empty_list "Plugin: Empty list"
run_test test_plugin_whitespace_list "Plugin: Whitespace-only list"
run_test test_plugin_case_sensitive "Plugin: Case sensitive"

# MCP server matching tests
run_test test_mcp_match_filesystem "MCP: Match filesystem"
run_test test_mcp_match_github "MCP: Match github"
run_test test_mcp_match_figma_desktop "MCP: Match figma-desktop"
run_test test_mcp_no_match_nonexistent "MCP: No match for nonexistent"
run_test test_mcp_no_match_partial "MCP: No match for partial name"
run_test test_mcp_no_match_contains "MCP: No match for substring"
run_test test_mcp_no_match_similar_prefix "MCP: Distinguish similar prefixes"
run_test test_mcp_match_with_hyphen_prefix "MCP: Match hyphenated name"
run_test test_mcp_empty_list "MCP: Empty list"

# Git URL parsing tests
run_test test_parse_https_github "Git URL: HTTPS GitHub"
run_test test_parse_https_gitlab "Git URL: HTTPS GitLab"
run_test test_parse_https_self_hosted "Git URL: HTTPS self-hosted"
run_test test_parse_ssh_shorthand_github "Git URL: SSH shorthand GitHub"
run_test test_parse_ssh_shorthand_gitlab "Git URL: SSH shorthand GitLab"
run_test test_parse_ssh_shorthand_self_hosted "Git URL: SSH shorthand self-hosted"
run_test test_parse_ssh_url_github "Git URL: SSH URL GitHub"
run_test test_parse_ssh_url_with_port "Git URL: SSH URL with port"
run_test test_parse_https_with_port "Git URL: HTTPS with port"
run_test test_parse_empty_url "Git URL: Empty"
run_test test_parse_invalid_url "Git URL: Invalid"
run_test test_parse_http_url "Git URL: HTTP"

# Git platform classification tests
run_test test_classify_github "Git classify: GitHub"
run_test test_classify_gitlab "Git classify: GitLab"
run_test test_classify_self_hosted_gitlab "Git classify: Self-hosted GitLab"
run_test test_classify_gitlab_subdomain "Git classify: GitLab subdomain"
run_test test_classify_unknown "Git classify: Unknown host"
run_test test_classify_self_hosted_git "Git classify: Self-hosted git"
run_test test_classify_empty "Git classify: Empty"

# Edge cases and regression tests
run_test test_plugin_special_characters_in_name "Edge: Plugin with numbers"
run_test test_mcp_server_with_numbers "Edge: MCP server with numbers"
run_test test_mcp_no_false_positive_on_description "Edge: No false positive on description"
run_test test_plugin_marketplace_variation "Edge: Different marketplace"

# Generate test report
generate_report
