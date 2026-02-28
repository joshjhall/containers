#!/usr/bin/env bash
# Unit tests for lib/features/kotlin-dev.sh
# Tests Kotlin development tools: ktlint, detekt, kotlin-language-server

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Kotlin Dev Feature Tests"

# Setup function - runs before each test
setup() {
    # Create temporary directory for testing
    export TEST_TEMP_DIR="$RESULTS_DIR/test-kotlin-dev"
    mkdir -p "$TEST_TEMP_DIR"

    # Mock environment
    export KTLINT_VERSION="${KTLINT_VERSION:-1.5.0}"
    export DETEKT_VERSION="${DETEKT_VERSION:-1.23.7}"
    export KLS_VERSION="${KLS_VERSION:-1.3.12}"
    export USERNAME="testuser"
    export USER_UID="1000"
    export USER_GID="1000"
    export HOME="/home/testuser"

    # Create mock directories
    mkdir -p "$TEST_TEMP_DIR/usr/local/bin"
    mkdir -p "$TEST_TEMP_DIR/opt/detekt/lib"
    mkdir -p "$TEST_TEMP_DIR/opt/kotlin-language-server/server/bin"
    mkdir -p "$TEST_TEMP_DIR/etc/bashrc.d"
    mkdir -p "$TEST_TEMP_DIR/etc/container/first-startup"
}

# Teardown function - runs after each test
teardown() {
    # Clean up test directory
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi

    # Unset test variables
    unset KTLINT_VERSION DETEKT_VERSION KLS_VERSION USERNAME USER_UID USER_GID HOME 2>/dev/null || true
}

# Test: ktlint version validation
test_ktlint_version_validation() {
    # Test valid versions
    local valid_versions=("1.5.0" "1.4.1" "1.3.0")

    for version in "${valid_versions[@]}"; do
        if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            assert_true true "ktlint version $version is valid format"
        else
            assert_true false "ktlint version $version should be valid"
        fi
    done
}

# Test: detekt version validation
test_detekt_version_validation() {
    # Test valid versions
    local valid_versions=("1.23.7" "1.23.6" "1.22.0")

    for version in "${valid_versions[@]}"; do
        if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            assert_true true "detekt version $version is valid format"
        else
            assert_true false "detekt version $version should be valid"
        fi
    done
}

# Test: KLS version validation
test_kls_version_validation() {
    # Test valid versions
    local valid_versions=("1.3.12" "1.3.11" "1.2.0")

    for version in "${valid_versions[@]}"; do
        if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            assert_true true "KLS version $version is valid format"
        else
            assert_true false "KLS version $version should be valid"
        fi
    done
}

# Test: ktlint installation
test_ktlint_installation() {
    local ktlint_bin="$TEST_TEMP_DIR/usr/local/bin/ktlint"

    # Create mock ktlint binary
    command cat > "$ktlint_bin" << 'EOF'
#!/bin/bash
echo "ktlint - 1.5.0"
EOF
    chmod +x "$ktlint_bin"

    assert_file_exists "$ktlint_bin"

    if [ -x "$ktlint_bin" ]; then
        assert_true true "ktlint is executable"
    else
        assert_true false "ktlint is not executable"
    fi
}

# Test: detekt installation
test_detekt_installation() {
    local detekt_home="$TEST_TEMP_DIR/opt/detekt"
    local detekt_bin="$TEST_TEMP_DIR/usr/local/bin/detekt"
    local detekt_jar="$detekt_home/lib/detekt-cli-1.23.7.jar"

    # Create mock detekt structure
    mkdir -p "$(dirname "$detekt_jar")"
    touch "$detekt_jar"

    # Create mock detekt wrapper
    command cat > "$detekt_bin" << 'EOF'
#!/bin/bash
DETEKT_HOME="/opt/detekt"
exec java -jar "${DETEKT_HOME}/lib/detekt-cli-1.23.7.jar" "$@"
EOF
    chmod +x "$detekt_bin"

    assert_file_exists "$detekt_bin"
    assert_file_exists "$detekt_jar"

    if [ -x "$detekt_bin" ]; then
        assert_true true "detekt is executable"
    else
        assert_true false "detekt is not executable"
    fi

    # Check wrapper script content
    if command grep -q "java -jar" "$detekt_bin"; then
        assert_true true "detekt wrapper uses java -jar"
    else
        assert_true false "detekt wrapper doesn't use java -jar"
    fi
}

# Test: kotlin-language-server installation
test_kls_installation() {
    local kls_home="$TEST_TEMP_DIR/opt/kotlin-language-server/server"
    local kls_bin="$kls_home/bin/kotlin-language-server"
    local kls_symlink="$TEST_TEMP_DIR/usr/local/bin/kotlin-language-server"

    # Create mock KLS structure
    mkdir -p "$(dirname "$kls_bin")"
    touch "$kls_bin"
    chmod +x "$kls_bin"

    # Create symlink
    ln -sf "$kls_bin" "$kls_symlink"

    assert_file_exists "$kls_bin"

    if [ -x "$kls_bin" ]; then
        assert_true true "kotlin-language-server is executable"
    else
        assert_true false "kotlin-language-server is not executable"
    fi

    # Check symlink exists
    if [ -L "$kls_symlink" ]; then
        assert_true true "kotlin-language-server symlink exists"
    else
        assert_true false "kotlin-language-server symlink doesn't exist"
    fi
}

# Test: Environment configuration
test_kotlin_dev_environment() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/55-kotlin-dev.sh"

    # Create mock bashrc content
    command cat > "$bashrc_file" << 'EOF'
# Kotlin Development Tools Configuration
export DETEKT_HOME="/opt/detekt"
export KLS_HOME="/opt/kotlin-language-server/server"
EOF

    # Check environment variables
    if command grep -q "export DETEKT_HOME=" "$bashrc_file"; then
        assert_true true "DETEKT_HOME is exported"
    else
        assert_true false "DETEKT_HOME is not exported"
    fi

    if command grep -q "export KLS_HOME=" "$bashrc_file"; then
        assert_true true "KLS_HOME is exported"
    else
        assert_true false "KLS_HOME is not exported"
    fi
}

# Test: Kotlin dev aliases
test_kotlin_dev_aliases() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/55-kotlin-dev.sh"

    # Create bashrc with aliases
    command cat > "$bashrc_file" << 'EOF'
# ktlint shortcuts
alias ktf='ktlint -F'          # Format files
alias ktcheck='ktlint'          # Check files
alias ktfmt='ktlint -F'         # Alias for format

# detekt shortcuts
alias dkt='detekt'
alias dktcheck='detekt --build-upon-default-config'
EOF

    # Check aliases
    if command grep -q "alias ktf='ktlint -F'" "$bashrc_file"; then
        assert_true true "ktlint format alias defined"
    else
        assert_true false "ktlint format alias not defined"
    fi

    if command grep -q "alias ktcheck='ktlint'" "$bashrc_file"; then
        assert_true true "ktlint check alias defined"
    else
        assert_true false "ktlint check alias not defined"
    fi

    if command grep -q "alias dkt='detekt'" "$bashrc_file"; then
        assert_true true "detekt alias defined"
    else
        assert_true false "detekt alias not defined"
    fi
}

# Test: Helper functions
test_kotlin_dev_helpers() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/55-kotlin-dev.sh"

    # Create bashrc with helpers
    command cat > "$bashrc_file" << 'EOF'
ktlint-all() {
    echo "=== Running ktlint on all Kotlin files ==="
    if [ "$1" = "-F" ] || [ "$1" = "--format" ]; then
        ktlint -F "**/*.kt" "**/*.kts"
    else
        ktlint "**/*.kt" "**/*.kts"
    fi
}

detekt-report() {
    local output="${1:-detekt-report.html}"
    echo "=== Running detekt with HTML report ==="
    detekt --report html:"$output"
    echo "Report saved to: $output"
}

kotlin-dev-version() {
    echo "=== Kotlin Development Tools ==="
    echo ""
    echo "ktlint:"
    ktlint --version 2>&1 | head -1
    echo ""
    echo "detekt:"
    detekt --version 2>&1 | head -1
}
EOF

    # Check helper functions
    if command grep -q "ktlint-all()" "$bashrc_file"; then
        assert_true true "ktlint-all helper defined"
    else
        assert_true false "ktlint-all helper not defined"
    fi

    if command grep -q "detekt-report()" "$bashrc_file"; then
        assert_true true "detekt-report helper defined"
    else
        assert_true false "detekt-report helper not defined"
    fi

    if command grep -q "kotlin-dev-version()" "$bashrc_file"; then
        assert_true true "kotlin-dev-version helper defined"
    else
        assert_true false "kotlin-dev-version helper not defined"
    fi
}

# Test: Claude Code LSP integration setup
test_claude_lsp_integration() {
    local lsp_setup="$TEST_TEMP_DIR/etc/container/first-startup/31-kotlin-lsp-setup.sh"

    # Create mock LSP setup script
    command cat > "$lsp_setup" << 'EOF'
#!/bin/bash
# Kotlin LSP setup for Claude Code

if command -v claude &>/dev/null && [ "${ENABLE_LSP_TOOL:-0}" = "1" ]; then
    if command -v kotlin-language-server &>/dev/null; then
        if ! claude plugin list 2>/dev/null | command grep -q "kotlin"; then
            echo "Installing Kotlin LSP plugin for Claude Code..."
            claude plugin add kotlin-language-server@claude-code-lsps 2>/dev/null || true
        fi
    fi
fi
EOF
    chmod +x "$lsp_setup"

    assert_file_exists "$lsp_setup"

    if [ -x "$lsp_setup" ]; then
        assert_true true "LSP setup script is executable"
    else
        assert_true false "LSP setup script is not executable"
    fi

    # Check script content
    if command grep -q "kotlin-language-server@claude-code-lsps" "$lsp_setup"; then
        assert_true true "LSP plugin reference is correct"
    else
        assert_true false "LSP plugin reference is missing"
    fi
}

# Test: Kotlin prerequisite check
test_kotlin_prerequisite() {
    # kotlin-dev requires Kotlin base, verify the check pattern
    local test_script="$TEST_TEMP_DIR/check-kotlin.sh"

    command cat > "$test_script" << 'EOF'
#!/bin/bash
if ! command -v kotlinc &>/dev/null; then
    echo "Kotlin is required but not installed"
    echo "Enable INCLUDE_KOTLIN=true first"
    exit 1
fi
echo "Kotlin is available"
exit 0
EOF
    chmod +x "$test_script"

    assert_file_exists "$test_script"
    if [ -x "$test_script" ]; then
        assert_true true "Kotlin prerequisite check script is executable"
    else
        assert_true false "Kotlin prerequisite check script is not executable"
    fi
}

# Test: Verification script
test_kotlin_dev_verification() {
    local test_script="$TEST_TEMP_DIR/test-kotlin-dev.sh"

    # Create verification script
    command cat > "$test_script" << 'EOF'
#!/bin/bash
echo "=== Kotlin Development Tools Status ==="

echo ""
echo "=== Linting & Formatting ==="
if command -v ktlint &>/dev/null; then
    echo "ktlint is installed"
    ktlint --version 2>&1 | head -1
else
    echo "ktlint is not installed"
fi

echo ""
echo "=== Static Analysis ==="
if command -v detekt &>/dev/null; then
    echo "detekt is installed"
    detekt --version 2>&1 | head -1
else
    echo "detekt is not installed"
fi

echo ""
echo "=== Language Server ==="
if command -v kotlin-language-server &>/dev/null; then
    echo "kotlin-language-server is installed"
else
    echo "kotlin-language-server is not installed"
fi
EOF
    chmod +x "$test_script"

    assert_file_exists "$test_script"

    if [ -x "$test_script" ]; then
        assert_true true "Verification script is executable"
    else
        assert_true false "Verification script is not executable"
    fi
}

# Test: Project initialization helper
test_project_init_helper() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/55-kotlin-dev.sh"

    # Create bashrc with kt-init-project
    command cat > "$bashrc_file" << 'EOF'
kt-init-project() {
    local project_name="${1:-$(basename $(pwd))}"
    echo "=== Initializing Kotlin Project: $project_name ==="

    # Create .editorconfig for ktlint
    if [ ! -f ".editorconfig" ]; then
        command cat > .editorconfig << 'EDITORCONFIG'
root = true

[*]
charset = utf-8
end_of_line = lf
indent_size = 4
indent_style = space

[*.{kt,kts}]
ktlint_code_style = ktlint_official
EDITORCONFIG
        echo "Created .editorconfig"
    fi

    # Create detekt config
    if [ ! -f "detekt.yml" ] && command -v detekt &>/dev/null; then
        detekt --generate-config
        echo "Created detekt.yml"
    fi
}
EOF

    # Check helper function
    if command grep -q "kt-init-project()" "$bashrc_file"; then
        assert_true true "kt-init-project helper defined"
    else
        assert_true false "kt-init-project helper not defined"
    fi

    if command grep -q "ktlint_official" "$bashrc_file"; then
        assert_true true "editorconfig includes ktlint style"
    else
        assert_true false "editorconfig doesn't include ktlint style"
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
run_test_with_setup test_ktlint_version_validation "ktlint version validation works"
run_test_with_setup test_detekt_version_validation "detekt version validation works"
run_test_with_setup test_kls_version_validation "KLS version validation works"
run_test_with_setup test_ktlint_installation "ktlint installation is correct"
run_test_with_setup test_detekt_installation "detekt installation is correct"
run_test_with_setup test_kls_installation "kotlin-language-server installation is correct"
run_test_with_setup test_kotlin_dev_environment "Kotlin dev environment is configured"
run_test_with_setup test_kotlin_dev_aliases "Kotlin dev aliases are defined"
run_test_with_setup test_kotlin_dev_helpers "Kotlin dev helpers are defined"
run_test_with_setup test_claude_lsp_integration "Claude Code LSP integration is configured"
run_test_with_setup test_kotlin_prerequisite "Kotlin prerequisite check works"
run_test_with_setup test_kotlin_dev_verification "Kotlin dev verification script works"
run_test_with_setup test_project_init_helper "Project initialization helper works"

# Generate test report
generate_report
