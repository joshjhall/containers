#!/usr/bin/env bash
# Test Claude Code setup (CLI, MCP servers, and plugin integrations)
#
# This test verifies the Claude Code setup installed by claude-code-setup.sh:
# - Claude Code CLI installation
# - MCP servers: filesystem, github, gitlab (npm packages)
# - bash-language-server (npm package)
# - claude-setup command for plugin/MCP configuration
# - Build-time config file for runtime plugin installation
#
# Note: claude-code-setup.sh runs after dev-tools.sh and reads enabled-features.conf
# Note: INCLUDE_MCP_SERVERS is deprecated (kept for backward compatibility)

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the test framework
source "$SCRIPT_DIR/../../framework.sh"

# Initialize the test framework
init_test_framework

# For standalone testing, we build from containers directory
export BUILD_CONTEXT="$CONTAINERS_DIR"

# Define test suite
test_suite "Claude Code Setup (CLI, MCP, Plugins)"

# Test: Claude Code setup with dev-tools + Node.js
test_claude_code_setup_with_node() {
    local image="test-claude-code-setup-$$"
    echo "Building image with INCLUDE_DEV_TOOLS=true and INCLUDE_NODE=true"

    # Build with dev-tools and Node.js (no INCLUDE_MCP_SERVERS needed)
    assert_build_succeeds "Dockerfile" \
        --build-arg PROJECT_PATH=. \
        --build-arg PROJECT_NAME=test-claude-code-setup \
        --build-arg INCLUDE_DEV_TOOLS=true \
        --build-arg INCLUDE_NODE=true \
        -t "$image"

    # Verify Node.js is installed
    assert_executable_in_path "$image" "node"
    assert_executable_in_path "$image" "npm"

    # Verify MCP servers are installed globally (check /usr/local where build installs them)
    assert_command_in_container "$image" \
        "test -d /usr/local/lib/node_modules/@modelcontextprotocol/server-filesystem && echo 'installed'" \
        "installed"

    assert_command_in_container "$image" \
        "test -d /usr/local/lib/node_modules/@modelcontextprotocol/server-github && echo 'installed'" \
        "installed"

    assert_command_in_container "$image" \
        "test -d /usr/local/lib/node_modules/@modelcontextprotocol/server-gitlab && echo 'installed'" \
        "installed"

    # Verify bash-language-server is installed
    assert_command_in_container "$image" \
        "test -d /usr/local/lib/node_modules/bash-language-server && echo 'installed'" \
        "installed"
}

# Test: claude-setup command exists and is executable
test_claude_setup_command() {
    local image="${IMAGE_TO_TEST:-test-claude-code-setup-$$}"

    # Verify claude-setup command exists
    assert_executable_in_path "$image" "claude-setup"

    # Verify it has correct permissions
    assert_command_in_container "$image" \
        "test -x /usr/local/bin/claude-setup && echo 'executable'" \
        "executable"
}

# Test: Correct marketplace used in claude-setup script
test_correct_marketplace() {
    local image="${IMAGE_TO_TEST:-test-claude-code-setup-$$}"

    # Verify claude-setup uses correct marketplace (claude-plugins-official)
    assert_command_in_container "$image" \
        "grep -q 'claude-plugins-official' /usr/local/bin/claude-setup && echo 'correct'" \
        "correct"

    # Verify old marketplace (Piebald-AI) is NOT used
    assert_command_in_container "$image" \
        "grep -q 'Piebald-AI' /usr/local/bin/claude-setup && echo 'old' || echo 'good'" \
        "good"
}

# Test: Correct plugin names in claude-setup script
test_plugin_names() {
    local image="${IMAGE_TO_TEST:-test-claude-code-setup-$$}"

    # Verify correct LSP plugin names are used
    assert_command_in_container "$image" \
        "grep -q 'rust-analyzer-lsp' /usr/local/bin/claude-setup && echo 'correct'" \
        "correct"

    assert_command_in_container "$image" \
        "grep -q 'pyright-lsp' /usr/local/bin/claude-setup && echo 'correct'" \
        "correct"

    assert_command_in_container "$image" \
        "grep -q 'typescript-lsp' /usr/local/bin/claude-setup && echo 'correct'" \
        "correct"

    assert_command_in_container "$image" \
        "grep -q 'kotlin-lsp' /usr/local/bin/claude-setup && echo 'correct'" \
        "correct"

    # Verify core plugins are listed
    assert_command_in_container "$image" \
        "grep -q 'install_plugin \"figma\"' /usr/local/bin/claude-setup && echo 'has figma'" \
        "has figma"

    assert_command_in_container "$image" \
        "grep -q 'install_plugin \"pr-review-toolkit\"' /usr/local/bin/claude-setup && echo 'has pr-review'" \
        "has pr-review"
}

# Test: Build-time config file created with correct flags
test_enabled_features_config() {
    local image="test-claude-config-$$"

    # Build with specific features enabled
    assert_build_succeeds "Dockerfile" \
        --build-arg PROJECT_PATH=. \
        --build-arg PROJECT_NAME=test \
        --build-arg INCLUDE_DEV_TOOLS=true \
        --build-arg INCLUDE_NODE=true \
        --build-arg INCLUDE_PYTHON_DEV=true \
        --build-arg INCLUDE_RUST_DEV=true \
        -t "$image"

    # Verify config file exists
    assert_command_in_container "$image" \
        "test -f /etc/container/config/enabled-features.conf && echo 'exists'" \
        "exists"

    # Verify Python flag is set correctly
    assert_command_in_container "$image" \
        "grep 'INCLUDE_PYTHON_DEV=true' /etc/container/config/enabled-features.conf && echo 'python'" \
        "python"

    # Verify Rust flag is set correctly
    assert_command_in_container "$image" \
        "grep 'INCLUDE_RUST_DEV=true' /etc/container/config/enabled-features.conf && echo 'rust'" \
        "rust"

    # Verify Node flag is set (should be false since we used INCLUDE_NODE not INCLUDE_NODE_DEV)
    assert_command_in_container "$image" \
        "grep 'INCLUDE_NODE_DEV=false' /etc/container/config/enabled-features.conf && echo 'node_dev_false'" \
        "node_dev_false"
}

# Test: Figma MCP is configured in claude-setup script
test_figma_mcp() {
    local image="${IMAGE_TO_TEST:-test-claude-code-setup-$$}"

    # Verify figma-desktop MCP is configured
    assert_command_in_container "$image" \
        "grep -q 'figma-desktop' /usr/local/bin/claude-setup && echo 'has figma'" \
        "has figma"

    # Verify Docker host URL is used
    assert_command_in_container "$image" \
        "grep -q 'host.docker.internal:3845' /usr/local/bin/claude-setup && echo 'has docker host'" \
        "has docker host"
}

# Test: Git platform detection in claude-setup script
test_git_platform_detection() {
    local image="${IMAGE_TO_TEST:-test-claude-code-setup-$$}"

    # Verify claude-setup has git platform detection
    assert_command_in_container "$image" \
        "grep -q 'detect_git_platform' /usr/local/bin/claude-setup && echo 'has detection'" \
        "has detection"

    # Verify GitHub detection
    assert_command_in_container "$image" \
        "grep -q 'github.com' /usr/local/bin/claude-setup && echo 'detects github'" \
        "detects github"

    # Verify GitLab detection
    assert_command_in_container "$image" \
        "grep -q 'gitlab' /usr/local/bin/claude-setup && echo 'detects gitlab'" \
        "detects gitlab"

    # Verify fallback to both when ambiguous
    assert_command_in_container "$image" \
        "grep -q 'installing both GitHub and GitLab' /usr/local/bin/claude-setup && echo 'has fallback'" \
        "has fallback"
}

# Test: MCP idempotency check
test_mcp_idempotency() {
    local image="${IMAGE_TO_TEST:-test-claude-code-setup-$$}"

    # Verify claude-setup has MCP server existence check
    assert_command_in_container "$image" \
        "grep -q 'has_mcp_server' /usr/local/bin/claude-setup && echo 'is idempotent'" \
        "is idempotent"
}

# Test: Plugin installation skipped when not authenticated
test_plugin_auth_check() {
    local image="${IMAGE_TO_TEST:-test-claude-code-setup-$$}"

    # Verify claude-setup has authentication check
    assert_command_in_container "$image" \
        "grep -q 'is_claude_authenticated' /usr/local/bin/claude-setup && echo 'has auth check'" \
        "has auth check"

    # Verify claude-setup checks for interactive authentication (not env vars)
    assert_command_in_container "$image" \
        "grep -q 'Run Claude and authenticate' /usr/local/bin/claude-setup && echo 'requires interactive auth'" \
        "requires interactive auth"
}

# Test: Backward compatibility - deprecated INCLUDE_MCP_SERVERS still triggers Node.js
test_backward_compat_mcp_servers_flag() {
    local image="test-claude-code-setup-compat-$$"

    # Build with deprecated INCLUDE_MCP_SERVERS flag
    assert_build_succeeds "Dockerfile" \
        --build-arg PROJECT_PATH=. \
        --build-arg PROJECT_NAME=test-claude-code-setup \
        --build-arg INCLUDE_NODE=false \
        --build-arg INCLUDE_DEV_TOOLS=true \
        --build-arg INCLUDE_MCP_SERVERS=true \
        -t "$image"

    # Verify Node.js was still installed (backward compat)
    assert_executable_in_path "$image" "node"
}

# Test: MCP not installed without Node.js
test_mcp_requires_node() {
    local image="test-claude-no-node-$$"

    # Build with dev-tools but no Node.js
    assert_build_succeeds "Dockerfile" \
        --build-arg PROJECT_PATH=. \
        --build-arg PROJECT_NAME=test-claude-no-node \
        --build-arg INCLUDE_DEV_TOOLS=true \
        --build-arg INCLUDE_NODE=false \
        --build-arg INCLUDE_MCP_SERVERS=false \
        -t "$image"

    # Verify MCP servers are NOT installed when Node.js is not available
    assert_command_in_container "$image" \
        "test -d /usr/local/lib/node_modules/@modelcontextprotocol/server-filesystem && echo 'installed' || echo 'not installed'" \
        "not installed"
}

# Run all tests
run_test test_claude_code_setup_with_node "Claude Code setup with dev-tools + Node.js"
run_test test_claude_setup_command "claude-setup command exists"
run_test test_correct_marketplace "claude-setup uses correct marketplace"
run_test test_plugin_names "claude-setup uses correct plugin names"
run_test test_figma_mcp "Figma MCP is configured"
run_test test_git_platform_detection "Git platform detection in claude-setup"
run_test test_mcp_idempotency "MCP configuration is idempotent"
run_test test_plugin_auth_check "Plugin installation has auth check"

# Skip tests that require building new images if using pre-built image
if [ -z "${IMAGE_TO_TEST:-}" ]; then
    run_test test_enabled_features_config "Build-time config file created with correct flags"
    run_test test_backward_compat_mcp_servers_flag "Backward compat: INCLUDE_MCP_SERVERS triggers Node.js"
    run_test test_mcp_requires_node "MCP not installed without Node.js"
fi

# Generate test report
generate_report
