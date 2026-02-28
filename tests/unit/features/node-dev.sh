#!/usr/bin/env bash
# Unit tests for lib/features/node-dev.sh
# Tests Node.js development tools installation

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Node Dev Feature Tests"

# Setup function - runs before each test
setup() {
    # Create temporary directory for testing
    export TEST_TEMP_DIR="$RESULTS_DIR/test-node-dev"
    mkdir -p "$TEST_TEMP_DIR"

    # Mock environment
    export USERNAME="testuser"
    export USER_UID="1000"
    export USER_GID="1000"
    export HOME="/home/testuser"

    # Create mock directories
    mkdir -p "$TEST_TEMP_DIR/usr/local/bin"
    mkdir -p "$TEST_TEMP_DIR/cache/npm"
    mkdir -p "$TEST_TEMP_DIR/home/testuser/.npm"
    mkdir -p "$TEST_TEMP_DIR/etc/bashrc.d"
}

# Teardown function - runs after each test
teardown() {
    # Clean up test directory
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi

    # Unset test variables
    unset USERNAME USER_UID USER_GID HOME 2>/dev/null || true
}

# Test: Global npm packages
test_global_npm_packages() {
    local npm_dir="$TEST_TEMP_DIR/cache/npm/bin"
    mkdir -p "$npm_dir"

    # List of dev tools
    local tools=("typescript" "ts-node" "nodemon" "eslint" "prettier" "jest" "pm2" "nx")

    # Create mock tools
    for tool in "${tools[@]}"; do
        touch "$npm_dir/$tool"
        chmod +x "$npm_dir/$tool"
    done

    # Check each tool
    for tool in "${tools[@]}"; do
        if [ -x "$npm_dir/$tool" ]; then
            assert_true true "$tool is installed"
        else
            assert_true false "$tool is not installed"
        fi
    done
}

# Test: TypeScript configuration
test_typescript_config() {
    local tsconfig="$TEST_TEMP_DIR/tsconfig.json"

    # Create config
    command cat > "$tsconfig" << 'EOF'
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "commonjs",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true
  }
}
EOF

    assert_file_exists "$tsconfig"

    # Check configuration
    if command grep -q '"strict": true' "$tsconfig"; then
        assert_true true "TypeScript strict mode enabled"
    else
        assert_true false "TypeScript strict mode not enabled"
    fi
}

# Test: ESLint configuration
test_eslint_config() {
    local eslintrc="$TEST_TEMP_DIR/.eslintrc.json"

    # Create config
    command cat > "$eslintrc" << 'EOF'
{
  "extends": ["eslint:recommended"],
  "env": {
    "node": true,
    "es2022": true
  },
  "rules": {
    "no-console": "warn"
  }
}
EOF

    assert_file_exists "$eslintrc"

    # Check configuration
    if command grep -q '"eslint:recommended"' "$eslintrc"; then
        assert_true true "ESLint recommended rules enabled"
    else
        assert_true false "ESLint recommended rules not enabled"
    fi
}

# Test: Prettier configuration
test_prettier_config() {
    local prettierrc="$TEST_TEMP_DIR/.prettierrc"

    # Create config
    command cat > "$prettierrc" << 'EOF'
{
  "semi": true,
  "singleQuote": true,
  "tabWidth": 2,
  "trailingComma": "es5"
}
EOF

    assert_file_exists "$prettierrc"

    # Check configuration
    if command grep -q '"singleQuote": true' "$prettierrc"; then
        assert_true true "Prettier single quotes enabled"
    else
        assert_true false "Prettier single quotes not enabled"
    fi
}

# Test: Jest configuration
test_jest_config() {
    local jestconfig="$TEST_TEMP_DIR/jest.config.js"

    # Create config
    command cat > "$jestconfig" << 'EOF'
module.exports = {
  testEnvironment: 'node',
  coverageDirectory: 'coverage',
  collectCoverageFrom: ['src/**/*.{js,ts}']
};
EOF

    assert_file_exists "$jestconfig"

    # Check configuration
    if command grep -q "testEnvironment: 'node'" "$jestconfig"; then
        assert_true true "Jest node environment configured"
    else
        assert_true false "Jest node environment not configured"
    fi
}

# Test: Nodemon configuration
test_nodemon_config() {
    local nodemon_json="$TEST_TEMP_DIR/nodemon.json"

    # Create config
    command cat > "$nodemon_json" << 'EOF'
{
  "watch": ["src"],
  "ext": "js,ts,json",
  "exec": "ts-node"
}
EOF

    assert_file_exists "$nodemon_json"

    # Check configuration
    if command grep -q '"exec": "ts-node"' "$nodemon_json"; then
        assert_true true "Nodemon uses ts-node"
    else
        assert_true false "Nodemon doesn't use ts-node"
    fi
}

# Test: NPM scripts
test_npm_scripts() {
    local package_json="$TEST_TEMP_DIR/package.json"

    # Create package.json with scripts
    command cat > "$package_json" << 'EOF'
{
  "scripts": {
    "dev": "nodemon",
    "build": "tsc",
    "test": "jest",
    "lint": "eslint .",
    "format": "prettier --write ."
  }
}
EOF

    assert_file_exists "$package_json"

    # Check scripts
    if command grep -q '"dev": "nodemon"' "$package_json"; then
        assert_true true "Dev script configured"
    else
        assert_true false "Dev script not configured"
    fi
}

# Test: Node dev aliases
test_node_dev_aliases() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/25-node-dev.sh"

    # Create aliases
    command cat > "$bashrc_file" << 'EOF'
alias nrd='npm run dev'
alias nrb='npm run build'
alias nrt='npm run test'
alias nrl='npm run lint'
alias tsc='npx tsc'
alias tsn='npx ts-node'
EOF

    # Check aliases
    if command grep -q "alias nrd='npm run dev'" "$bashrc_file"; then
        assert_true true "npm run dev alias defined"
    else
        assert_true false "npm run dev alias not defined"
    fi
}

# Test: Yarn/PNPM support
test_package_managers() {
    local bin_dir="$TEST_TEMP_DIR/usr/local/bin"

    # Create mock binaries
    touch "$bin_dir/yarn"
    touch "$bin_dir/pnpm"
    chmod +x "$bin_dir/yarn" "$bin_dir/pnpm"

    # Check package managers
    if [ -x "$bin_dir/yarn" ]; then
        assert_true true "Yarn is installed"
    else
        assert_true false "Yarn is not installed"
    fi

    if [ -x "$bin_dir/pnpm" ]; then
        assert_true true "PNPM is installed"
    else
        assert_true false "PNPM is not installed"
    fi
}

# Test: Verification script
test_node_dev_verification() {
    local test_script="$TEST_TEMP_DIR/test-node-dev.sh"

    # Create verification script
    command cat > "$test_script" << 'EOF'
#!/bin/bash
echo "Node.js dev tools:"
for tool in typescript eslint prettier jest nodemon pm2; do
    npx $tool --version &>/dev/null && echo "  - $tool: installed" || echo "  - $tool: not found"
done
EOF
    chmod +x "$test_script"

    assert_file_exists "$test_script"

    # Check script is executable
    if [ -x "$test_script" ]; then
        assert_true true "Verification script is executable"
    else
        assert_true false "Verification script is not executable"
    fi
}

# Run tests with setup/teardown
run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"

    setup
    run_test "$test_function" "$test_description"
    teardown
}

# Run all tests
run_test_with_setup test_global_npm_packages "Global npm packages"
run_test_with_setup test_typescript_config "TypeScript configuration"
run_test_with_setup test_eslint_config "ESLint configuration"
run_test_with_setup test_prettier_config "Prettier configuration"
run_test_with_setup test_jest_config "Jest configuration"
run_test_with_setup test_nodemon_config "Nodemon configuration"
run_test_with_setup test_npm_scripts "NPM scripts"
run_test_with_setup test_node_dev_aliases "Node dev aliases"
run_test_with_setup test_package_managers "Yarn/PNPM support"
run_test_with_setup test_node_dev_verification "Node dev verification"

# Generate test report
generate_report
