#!/usr/bin/env bash
# Test node-dev container build
#
# This test verifies the node-dev configuration that includes:
# - Node.js with development tools
# - 1Password CLI
# - Development tools (git, gh, fzf, etc.)
# - Database clients (PostgreSQL, Redis, SQLite)
# - Docker CLI

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the test framework
source "$SCRIPT_DIR/../../framework.sh"

# Initialize the test framework
init_test_framework

# For standalone testing, we build from containers directory
export BUILD_CONTEXT="$CONTAINERS_DIR"

# Define test suite
test_suite "Node Dev Container Build"

# Test: Node dev environment builds successfully
test_node_dev_build() {
    if [ -n "${IMAGE_TO_TEST:-}" ]; then
        local image="$IMAGE_TO_TEST"
    else
        local image="test-node-dev-$$"
        assert_build_succeeds "Dockerfile" \
            --build-arg PROJECT_PATH=. \
            --build-arg PROJECT_NAME=test-node-dev \
            --build-arg INCLUDE_NODE_DEV=true \
            --build-arg INCLUDE_OP=true \
            --build-arg INCLUDE_DEV_TOOLS=true \
            --build-arg INCLUDE_POSTGRES_CLIENT=true \
            --build-arg INCLUDE_REDIS_CLIENT=true \
            --build-arg INCLUDE_SQLITE_CLIENT=true \
            --build-arg INCLUDE_DOCKER=true \
            -t "$image"
    fi

    # Verify Node.js and package managers
    assert_executable_in_path "$image" "node"
    assert_executable_in_path "$image" "npm"
    assert_executable_in_path "$image" "yarn"
    # pnpm is checked in test_package_managers due to corepack signature issues

    # Verify Node.js development tools
    assert_executable_in_path "$image" "tsc"
    assert_executable_in_path "$image" "eslint"
    assert_executable_in_path "$image" "jest"

    # Verify dev tools
    assert_executable_in_path "$image" "git"
    assert_executable_in_path "$image" "gh"

    # Verify database clients
    assert_executable_in_path "$image" "psql"
    assert_executable_in_path "$image" "redis-cli"

    # Verify Docker CLI
    assert_executable_in_path "$image" "docker"
}

# Test: TypeScript compiler works
test_typescript() {
    local image="${IMAGE_TO_TEST:-test-node-dev-$$}"

    # Test TypeScript version
    assert_command_in_container "$image" "tsc --version" "Version"
}

# Test: Node package managers work
test_package_managers() {
    local image="${IMAGE_TO_TEST:-test-node-dev-$$}"

    # Test npm
    assert_command_in_container "$image" "npm --version" ""

    # Test yarn
    assert_command_in_container "$image" "yarn --version" ""

    # Test pnpm - Note: pnpm may fail with corepack signature verification issues
    # This is a known upstream issue with corepack, so we make this test non-fatal
    echo -n "  Testing pnpm... "
    if docker run --rm "$image" bash -c "pnpm --version" >/dev/null 2>&1; then
        echo -e "${TEST_COLOR_PASS}PASS${TEST_COLOR_RESET}"
        echo "    pnpm is functional"
    else
        echo -e "${TEST_COLOR_SKIP}SKIP${TEST_COLOR_RESET}"
        echo "    pnpm has known corepack signature issues"
        echo "    pnpm can be manually activated with: corepack enable && corepack prepare pnpm@9 --activate"
    fi
}

# Test: Development tools actually work
test_dev_tools_work() {
    local image="${IMAGE_TO_TEST:-test-node-dev-$$}"

    # ESLint can show version and works
    assert_command_in_container "$image" "eslint --version" ""

    # Prettier can show version and works
    assert_command_in_container "$image" "prettier --version" ""

    # Jest can show version
    assert_command_in_container "$image" "jest --version" ""

    # Webpack can show version
    assert_command_in_container "$image" "webpack --version" ""

    # Verify tools can actually process code
    assert_command_in_container "$image" "cd /tmp && echo 'const x = 1;' > test.js && prettier test.js" "const x = 1"
}

# Test: TypeScript compilation works
test_typescript_compilation() {
    local image="${IMAGE_TO_TEST:-test-node-dev-$$}"

    # Create a TypeScript file and compile it
    assert_command_in_container "$image" "cd /tmp && echo 'const greeting: string = \"hello\"; console.log(greeting);' > test.ts && tsc test.ts && node test.js" "hello"

    # ts-node version works (simpler test)
    assert_command_in_container "$image" "ts-node --version" ""
}

# Test: Package installation works
test_npm_install() {
    local image="${IMAGE_TO_TEST:-test-node-dev-$$}"

    # npm can install a package
    assert_command_in_container "$image" "cd /tmp && npm install lodash && node -e \"const _ = require('lodash'); console.log(_.VERSION)\"" ""
}

# Test: Build tools are functional
test_build_tools() {
    local image="${IMAGE_TO_TEST:-test-node-dev-$$}"

    # Vite can show version
    assert_command_in_container "$image" "vite --version" ""

    # esbuild can show version
    assert_command_in_container "$image" "esbuild --version" ""

    # Rollup can show version
    assert_command_in_container "$image" "rollup --version" ""
}

# Test: Cache directories are configured
test_node_cache() {
    local image="${IMAGE_TO_TEST:-test-node-dev-$$}"

    # npm cache directory exists and is writable
    assert_command_in_container "$image" "test -w /cache/npm && echo writable" "writable"

    # npm global directory exists and is writable
    assert_command_in_container "$image" "test -w /cache/npm-global && echo writable" "writable"
}

# Test: Database clients work
test_database_clients() {
    local image="${IMAGE_TO_TEST:-test-node-dev-$$}"

    # PostgreSQL client
    assert_command_in_container "$image" "psql --version" "psql"

    # Redis client
    assert_command_in_container "$image" "redis-cli --version" "redis-cli"

    # SQLite
    assert_command_in_container "$image" "sqlite3 --version" "3."
}

# Run all tests
run_test test_node_dev_build "Node dev environment builds successfully"
run_test test_typescript "TypeScript compiler is functional"
run_test test_package_managers "Node package managers work"
run_test test_dev_tools_work "Development tools work correctly"
run_test test_typescript_compilation "TypeScript compilation works"
run_test test_npm_install "npm can install packages"
run_test test_build_tools "Build tools are functional"
run_test test_node_cache "Node cache directories are configured"
run_test test_database_clients "Database clients are functional"

# Generate test report
generate_report
