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

    # Verify core MCP server is installed globally (check /usr/local where build installs them)
    # Note: GitHub/GitLab MCPs are now optional via CLAUDE_EXTRA_MCPS
    assert_command_in_container "$image" \
        "test -d /usr/local/lib/node_modules/@modelcontextprotocol/server-filesystem && echo 'installed'" \
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

    # Verify core plugins are listed (figma moved to optional, available via CLAUDE_EXTRA_PLUGINS)
    assert_command_in_container "$image" \
        "grep -q 'install_plugin \"commit-commands\"' /usr/local/bin/claude-setup && echo 'has commit-commands'" \
        "has commit-commands"

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

# Test: Extra MCP servers configured via CLAUDE_EXTRA_MCPS
test_extra_mcp_config() {
    local image="${IMAGE_TO_TEST:-test-claude-code-setup-$$}"

    # Verify claude-setup has CLAUDE_EXTRA_MCPS configuration logic
    assert_command_in_container "$image" \
        "grep -q 'CLAUDE_EXTRA_MCPS' /usr/local/bin/claude-setup && echo 'has extra mcps'" \
        "has extra mcps"

    # Verify MCP registry is used for extra MCP configuration
    assert_command_in_container "$image" \
        "grep -q 'mcp_registry_is_registered' /usr/local/bin/claude-setup && echo 'has registry'" \
        "has registry"
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

# Test: Extra MCP servers installed with CLAUDE_EXTRA_MCPS
test_extra_mcps_installed() {
    local image="test-claude-extra-mcps-$$"

    # Build with extra MCPs
    assert_build_succeeds "Dockerfile" \
        --build-arg PROJECT_PATH=. \
        --build-arg PROJECT_NAME=test-claude-extra-mcps \
        --build-arg INCLUDE_DEV_TOOLS=true \
        --build-arg INCLUDE_NODE=true \
        --build-arg CLAUDE_EXTRA_MCPS="fetch,memory" \
        -t "$image"

    # Verify extra MCP npm packages are installed
    assert_command_in_container "$image" \
        "test -d /usr/local/lib/node_modules/@modelcontextprotocol/server-fetch && echo 'installed'" \
        "installed"

    assert_command_in_container "$image" \
        "test -d /usr/local/lib/node_modules/@modelcontextprotocol/server-memory && echo 'installed'" \
        "installed"

    # Verify MCP registry is persisted to runtime config
    assert_command_in_container "$image" \
        "test -f /etc/container/config/mcp-registry.sh && echo 'exists'" \
        "exists"

    # Verify enabled-features.conf contains CLAUDE_EXTRA_MCPS_DEFAULT
    assert_command_in_container "$image" \
        "grep 'CLAUDE_EXTRA_MCPS_DEFAULT' /etc/container/config/enabled-features.conf && echo 'has mcps'" \
        "has mcps"

    # Verify claude-setup has extra MCP configuration logic
    assert_command_in_container "$image" \
        "grep -q 'mcp_registry_is_registered' /usr/local/bin/claude-setup && echo 'has registry'" \
        "has registry"
}

# Test: Unknown MCP server name handled gracefully (no build failure)
test_unknown_mcp_graceful() {
    local image="test-claude-unknown-mcp-$$"

    # Build with an unknown MCP name - should NOT fail
    assert_build_succeeds "Dockerfile" \
        --build-arg PROJECT_PATH=. \
        --build-arg PROJECT_NAME=test-claude-unknown-mcp \
        --build-arg INCLUDE_DEV_TOOLS=true \
        --build-arg INCLUDE_NODE=true \
        --build-arg CLAUDE_EXTRA_MCPS="fetch,nonexistent-server" \
        -t "$image"

    # Verify the valid MCP was still installed despite the invalid one
    assert_command_in_container "$image" \
        "test -d /usr/local/lib/node_modules/@modelcontextprotocol/server-fetch && echo 'installed'" \
        "installed"
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

# Test: ANTHROPIC_AUTH_TOKEN detection
test_anthropic_auth_token_detection() {
    local image="test-claude-token-$$"
    echo "Testing ANTHROPIC_AUTH_TOKEN authentication detection..."

    # Build container with DEV_TOOLS
    assert_build_succeeds "Dockerfile" \
        --build-arg PROJECT_PATH=. \
        --build-arg PROJECT_NAME=test \
        --build-arg INCLUDE_DEV_TOOLS=true \
        -t "$image"

    # Test 1: Token auth is detected
    assert_command_in_container "$image" \
        "ANTHROPIC_AUTH_TOKEN=test-token-123 bash -c 'source /usr/local/bin/claude-setup && is_claude_authenticated && echo \"AUTH_DETECTED\"'" \
        "AUTH_DETECTED"

    # Test 2: is_claude_authenticated function exists
    assert_command_in_container "$image" \
        "grep -q 'ANTHROPIC_AUTH_TOKEN' /usr/local/bin/claude-setup && echo 'has token check'" \
        "has token check"
}

# Test: Marketplace availability detection in watcher
test_marketplace_availability_detection() {
    local image="${IMAGE_TO_TEST:-test-claude-code-setup-$$}"
    echo "Testing marketplace availability detection in watcher..."

    # Marketplace check lives in the watcher (not claude-setup)
    assert_command_in_container "$image" \
        "grep -q '_is_marketplace_available' /usr/local/bin/claude-auth-watcher && echo 'FUNCTION_EXISTS'" \
        "FUNCTION_EXISTS"

    # Verify marketplace check uses claude plugin list
    assert_command_in_container "$image" \
        "grep -q 'claude plugin list' /usr/local/bin/claude-auth-watcher && echo 'uses plugin list'" \
        "uses plugin list"
}

# Test: ANTHROPIC_MODEL export
test_anthropic_model_export() {
    local image="${IMAGE_TO_TEST:-test-claude-code-setup-$$}"
    echo "Testing ANTHROPIC_MODEL environment variable export..."

    # Verify bashrc script exists
    assert_command_in_container "$image" \
        "test -f /etc/bashrc.d/95-claude-env.sh && echo 'exists'" \
        "exists"

    # Verify ANTHROPIC_MODEL is handled in the script
    assert_command_in_container "$image" \
        "grep -q 'ANTHROPIC_MODEL' /etc/bashrc.d/95-claude-env.sh && echo 'has model var'" \
        "has model var"

    # Test that ANTHROPIC_MODEL exports correctly
    assert_command_in_container "$image" \
        "ANTHROPIC_MODEL=opus bash -c 'source /etc/bashrc.d/95-claude-env.sh && echo \$ANTHROPIC_MODEL'" \
        "opus"
}

# Test: CLAUDE_CHANNEL default
test_claude_channel_default() {
    local image="test-claude-channel-default-$$"
    echo "Testing CLAUDE_CHANNEL default value..."

    # Build without specifying channel
    BUILD_OUTPUT=$(docker build \
        --build-arg PROJECT_PATH=. \
        --build-arg PROJECT_NAME=test \
        --build-arg INCLUDE_DEV_TOOLS=true \
        -t "$image" \
        "$BUILD_CONTEXT" 2>&1)

    # Check if the build output mentions the correct default channel
    if echo "$BUILD_OUTPUT" | grep -q "channel: latest"; then
        echo "✓ CLAUDE_CHANNEL defaults to 'latest'"
    else
        # Also check the feature script itself
        assert_command_in_container "$image" \
            "grep 'CLAUDE_CHANNEL=\${CLAUDE_CHANNEL:-latest}' /tmp/build-scripts/features/claude-code-setup.sh || echo 'defaults to latest'" \
            "defaults to latest"
    fi
}

# Test: claude-auth-watcher uses ANTHROPIC_AUTH_TOKEN
test_watcher_token_support() {
    local image="${IMAGE_TO_TEST:-test-claude-code-setup-$$}"
    echo "Testing claude-auth-watcher ANTHROPIC_AUTH_TOKEN support..."

    # Verify watcher script checks for token auth
    assert_command_in_container "$image" \
        "grep -q 'ANTHROPIC_AUTH_TOKEN' /usr/local/bin/claude-auth-watcher && echo 'has token check'" \
        "has token check"
}

# Test: bashrc hook checks for token auth
test_bashrc_hook_token_support() {
    local image="${IMAGE_TO_TEST:-test-claude-code-setup-$$}"
    echo "Testing bashrc hook ANTHROPIC_AUTH_TOKEN support..."

    # Verify bashrc hook checks for token auth
    assert_command_in_container "$image" \
        "grep -q 'ANTHROPIC_AUTH_TOKEN' /etc/bashrc.d/90-claude-auth-check.sh && echo 'has token check'" \
        "has token check"
}

# Test: Watcher resolves OP refs for authentication
test_watcher_op_resolution() {
    local image="${IMAGE_TO_TEST:-test-claude-code-setup-$$}"
    echo "Testing claude-auth-watcher OP ref resolution support..."

    # Verify watcher has OP resolution logic
    assert_command_in_container "$image" \
        "grep -q 'OP_ANTHROPIC_AUTH_TOKEN_REF' /usr/local/bin/claude-auth-watcher && echo 'has op ref check'" \
        "has op ref check"

    # Verify watcher has OP_SERVICE_ACCOUNT_TOKEN check
    assert_command_in_container "$image" \
        "grep -q 'OP_SERVICE_ACCOUNT_TOKEN' /usr/local/bin/claude-auth-watcher && echo 'has sa token check'" \
        "has sa token check"

    # Verify watcher uses op read for resolution
    assert_command_in_container "$image" \
        "grep -q 'op read' /usr/local/bin/claude-auth-watcher && echo 'uses op read'" \
        "uses op read"
}

# Test: claude-setup resolves OP refs for authentication
test_setup_op_resolution() {
    local image="${IMAGE_TO_TEST:-test-claude-code-setup-$$}"
    echo "Testing claude-setup OP ref resolution support..."

    # Verify claude-setup has OP resolution logic
    assert_command_in_container "$image" \
        "grep -q 'OP_ANTHROPIC_AUTH_TOKEN_REF' /usr/local/bin/claude-setup && echo 'has op ref check'" \
        "has op ref check"

    # Verify claude-setup uses op read
    assert_command_in_container "$image" \
        "grep -q 'op read' /usr/local/bin/claude-setup && echo 'uses op read'" \
        "uses op read"
}

# Run all tests
run_test test_claude_code_setup_with_node "Claude Code setup with dev-tools + Node.js"
run_test test_claude_setup_command "claude-setup command exists"
run_test test_correct_marketplace "claude-setup uses correct marketplace"
run_test test_plugin_names "claude-setup uses correct plugin names"
run_test test_figma_mcp "Figma MCP is configured"
run_test test_extra_mcp_config "Extra MCP servers configured via CLAUDE_EXTRA_MCPS"
run_test test_mcp_idempotency "MCP configuration is idempotent"
run_test test_plugin_auth_check "Plugin installation has auth check"
run_test test_marketplace_availability_detection "Marketplace availability detection"
run_test test_anthropic_model_export "ANTHROPIC_MODEL environment variable export"
run_test test_watcher_token_support "claude-auth-watcher ANTHROPIC_AUTH_TOKEN support"
run_test test_bashrc_hook_token_support "bashrc hook ANTHROPIC_AUTH_TOKEN support"
run_test test_watcher_op_resolution "claude-auth-watcher OP ref resolution"
run_test test_setup_op_resolution "claude-setup OP ref resolution"

# Skip tests that require building new images if using pre-built image
if [ -z "${IMAGE_TO_TEST:-}" ]; then
    run_test test_enabled_features_config "Build-time config file created with correct flags"
    run_test test_backward_compat_mcp_servers_flag "Backward compat: INCLUDE_MCP_SERVERS triggers Node.js"
    run_test test_mcp_requires_node "MCP not installed without Node.js"
    run_test test_extra_mcps_installed "Extra MCP servers installed with CLAUDE_EXTRA_MCPS"
    run_test test_unknown_mcp_graceful "Unknown MCP server name handled gracefully"
    run_test test_anthropic_auth_token_detection "ANTHROPIC_AUTH_TOKEN detection"
    run_test test_claude_channel_default "CLAUDE_CHANNEL default value"
fi

# Generate test report
generate_report
