#!/usr/bin/env bash
# Test Claude Code MCP server integrations
#
# This test verifies the claude-mcp configuration that includes:
# - @modelcontextprotocol/server-filesystem
# - @modelcontextprotocol/server-github
# - @modelcontextprotocol/server-gitlab
# - MCP configuration in ~/.claude/settings.json
#
# Note: Requires INCLUDE_DEV_TOOLS=true for Claude CLI to be present
# Note: INCLUDE_MCP_SERVERS=true auto-triggers Node.js installation

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the test framework
source "$SCRIPT_DIR/../../framework.sh"

# Initialize the test framework
init_test_framework

# For standalone testing, we build from containers directory
export BUILD_CONTEXT="$CONTAINERS_DIR"

# Define test suite
test_suite "Claude Code MCP Server Integrations"

# Test: MCP servers build and install
test_claude_mcp_install() {
    # Use pre-built image if provided, otherwise build locally
    if [ -n "${IMAGE_TO_TEST:-}" ]; then
        local image="$IMAGE_TO_TEST"
        echo "Testing pre-built image: $image"
    else
        local image="test-claude-mcp-$$"
        echo "Building image locally: $image"

        # Build with MCP servers enabled (triggers Node.js automatically)
        assert_build_succeeds "Dockerfile" \
            --build-arg PROJECT_PATH=. \
            --build-arg PROJECT_NAME=test-claude-mcp \
            --build-arg INCLUDE_DEV_TOOLS=true \
            --build-arg INCLUDE_MCP_SERVERS=true \
            -t "$image"
    fi

    # Verify Node.js was installed (required for MCP)
    assert_executable_in_path "$image" "node"
    assert_executable_in_path "$image" "npm"

    # Verify MCP servers are installed globally
    assert_command_in_container "$image" \
        "npm list -g @modelcontextprotocol/server-filesystem 2>/dev/null | grep -q server-filesystem && echo 'installed'" \
        "installed"

    assert_command_in_container "$image" \
        "npm list -g @modelcontextprotocol/server-github 2>/dev/null | grep -q server-github && echo 'installed'" \
        "installed"

    assert_command_in_container "$image" \
        "npm list -g @modelcontextprotocol/server-gitlab 2>/dev/null | grep -q server-gitlab && echo 'installed'" \
        "installed"
}

# Test: MCP configuration file is created
test_claude_mcp_config() {
    local image="${IMAGE_TO_TEST:-test-claude-mcp-$$}"

    # Verify settings.json exists
    assert_command_in_container "$image" \
        "test -f ~/.claude/settings.json && echo 'exists'" \
        "exists"

    # Verify settings.json contains MCP server configurations
    assert_command_in_container "$image" \
        "grep -q 'mcpServers' ~/.claude/settings.json && echo 'has mcp'" \
        "has mcp"

    assert_command_in_container "$image" \
        "grep -q 'filesystem' ~/.claude/settings.json && echo 'has filesystem'" \
        "has filesystem"

    assert_command_in_container "$image" \
        "grep -q 'github' ~/.claude/settings.json && echo 'has github'" \
        "has github"

    assert_command_in_container "$image" \
        "grep -q 'gitlab' ~/.claude/settings.json && echo 'has gitlab'" \
        "has gitlab"
}

# Test: MCP triggers Node.js installation automatically
test_claude_mcp_triggers_node() {
    local image="test-claude-mcp-node-$$"

    # Build with ONLY MCP servers (no INCLUDE_NODE)
    # This should still have Node.js because MCP triggers it
    assert_build_succeeds "Dockerfile" \
        --build-arg PROJECT_PATH=. \
        --build-arg PROJECT_NAME=test-claude-mcp \
        --build-arg INCLUDE_NODE=false \
        --build-arg INCLUDE_DEV_TOOLS=true \
        --build-arg INCLUDE_MCP_SERVERS=true \
        -t "$image"

    # Verify Node.js was installed even though INCLUDE_NODE=false
    assert_executable_in_path "$image" "node"
}

# Test: MCP servers can be disabled
test_claude_mcp_disabled() {
    local image="test-claude-mcp-disabled-$$"

    # Build with MCP servers disabled
    assert_build_succeeds "Dockerfile" \
        --build-arg PROJECT_PATH=. \
        --build-arg PROJECT_NAME=test-claude-mcp \
        --build-arg INCLUDE_DEV_TOOLS=true \
        --build-arg INCLUDE_MCP_SERVERS=false \
        -t "$image"

    # Verify MCP servers are NOT installed when disabled
    # Note: Node.js may or may not be present depending on other flags
    assert_command_in_container "$image" \
        "npm list -g @modelcontextprotocol/server-filesystem 2>/dev/null | grep -q server-filesystem && echo 'installed' || echo 'not installed'" \
        "not installed"
}

# Test: MCP doesn't run without dev-tools
test_claude_mcp_requires_devtools() {
    local image="test-claude-mcp-no-devtools-$$"

    # Build with MCP servers but NO dev-tools
    assert_build_succeeds "Dockerfile" \
        --build-arg PROJECT_PATH=. \
        --build-arg PROJECT_NAME=test-claude-mcp \
        --build-arg INCLUDE_DEV_TOOLS=false \
        --build-arg INCLUDE_MCP_SERVERS=true \
        -t "$image"

    # Node.js should still be installed (MCP triggers it)
    assert_executable_in_path "$image" "node"

    # But MCP servers should NOT be installed (no dev-tools = no Claude CLI)
    assert_command_in_container "$image" \
        "npm list -g @modelcontextprotocol/server-filesystem 2>/dev/null | grep -q server-filesystem && echo 'installed' || echo 'not installed'" \
        "not installed"
}

# Run all tests
run_test test_claude_mcp_install "MCP servers are installed correctly"
run_test test_claude_mcp_config "MCP configuration file is created"

# Skip additional tests if using pre-built image
if [ -z "${IMAGE_TO_TEST:-}" ]; then
    run_test test_claude_mcp_triggers_node "MCP triggers Node.js installation"
    run_test test_claude_mcp_disabled "MCP servers can be disabled"
    run_test test_claude_mcp_requires_devtools "MCP requires dev-tools to be enabled"
fi

# Generate test report
generate_report
