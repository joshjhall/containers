#!/usr/bin/env bash
# Test Claude Code LSP integrations
#
# This test verifies the claude-lsp configuration that includes:
# - Python LSP (pylsp) with black and ruff plugins when Python is installed
# - TypeScript language server when Node.js is installed
# - R language server when R is installed
#
# Note: Requires INCLUDE_DEV_TOOLS=true for Claude CLI to be present

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the test framework
source "$SCRIPT_DIR/../../framework.sh"

# Initialize the test framework
init_test_framework

# For standalone testing, we build from containers directory
export BUILD_CONTEXT="$CONTAINERS_DIR"

# Define test suite
test_suite "Claude Code LSP Integrations"

# Test: LSP integrations build with Python
test_claude_lsp_python() {
    # Use pre-built image if provided, otherwise build locally
    if [ -n "${IMAGE_TO_TEST:-}" ]; then
        local image="$IMAGE_TO_TEST"
        echo "Testing pre-built image: $image"
    else
        local image="test-claude-lsp-python-$$"
        echo "Building image locally: $image"

        # Build with Python dev and dev-tools (includes Claude CLI)
        assert_build_succeeds "Dockerfile" \
            --build-arg PROJECT_PATH=. \
            --build-arg PROJECT_NAME=test-claude-lsp \
            --build-arg INCLUDE_PYTHON_DEV=true \
            --build-arg INCLUDE_DEV_TOOLS=true \
            --build-arg INCLUDE_CLAUDE_INTEGRATIONS=true \
            -t "$image"
    fi

    # Verify Python LSP is installed
    assert_executable_in_path "$image" "pylsp"

    # Verify pylsp can start (check help output)
    assert_command_in_container "$image" "pylsp --help 2>&1 | head -1" "usage"
}

# Test: LSP integrations build with Node.js
test_claude_lsp_node() {
    local image="test-claude-lsp-node-$$"

    # Build with Node dev and dev-tools (includes Claude CLI)
    assert_build_succeeds "Dockerfile" \
        --build-arg PROJECT_PATH=. \
        --build-arg PROJECT_NAME=test-claude-lsp \
        --build-arg INCLUDE_NODE_DEV=true \
        --build-arg INCLUDE_DEV_TOOLS=true \
        --build-arg INCLUDE_CLAUDE_INTEGRATIONS=true \
        -t "$image"

    # Verify TypeScript language server is installed
    assert_executable_in_path "$image" "typescript-language-server"

    # Verify tsserver can show version
    assert_command_in_container "$image" "typescript-language-server --version" ""
}

# Test: LSP integrations can be disabled
test_claude_lsp_disabled() {
    local image="test-claude-lsp-disabled-$$"

    # Build with Python dev but LSP integrations disabled
    assert_build_succeeds "Dockerfile" \
        --build-arg PROJECT_PATH=. \
        --build-arg PROJECT_NAME=test-claude-lsp \
        --build-arg INCLUDE_PYTHON_DEV=true \
        --build-arg INCLUDE_DEV_TOOLS=true \
        --build-arg INCLUDE_CLAUDE_INTEGRATIONS=false \
        -t "$image"

    # Verify pylsp is NOT installed when disabled
    assert_command_in_container "$image" "command -v pylsp || echo 'not found'" "not found"
}

# Test: LSP doesn't run without dev-tools
test_claude_lsp_requires_devtools() {
    local image="test-claude-lsp-no-devtools-$$"

    # Build with Python dev but NO dev-tools
    assert_build_succeeds "Dockerfile" \
        --build-arg PROJECT_PATH=. \
        --build-arg PROJECT_NAME=test-claude-lsp \
        --build-arg INCLUDE_PYTHON_DEV=true \
        --build-arg INCLUDE_DEV_TOOLS=false \
        --build-arg INCLUDE_CLAUDE_INTEGRATIONS=true \
        -t "$image"

    # Verify pylsp is NOT installed (no dev-tools = no Claude CLI = no LSP)
    assert_command_in_container "$image" "command -v pylsp || echo 'not found'" "not found"
}

# Run all tests
run_test test_claude_lsp_python "Python LSP (pylsp) is installed with Python dev"

# Skip Node test if using pre-built image (it may not have Node)
if [ -z "${IMAGE_TO_TEST:-}" ]; then
    run_test test_claude_lsp_node "TypeScript LSP is installed with Node dev"
    run_test test_claude_lsp_disabled "LSP integrations can be disabled"
    run_test test_claude_lsp_requires_devtools "LSP requires dev-tools to be enabled"
fi

# Generate test report
generate_report
