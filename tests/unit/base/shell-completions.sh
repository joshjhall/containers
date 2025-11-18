#!/usr/bin/env bash
# Unit tests for shell completions
# Tests that completion scripts are properly generated and can be sourced

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Shell Completion Tests"

# Setup function - runs before each test
setup() {
    # Create temporary directory for testing
    export TEST_TEMP_DIR="$RESULTS_DIR/test-completions"
    mkdir -p "$TEST_TEMP_DIR"
    mkdir -p "$TEST_TEMP_DIR/etc/bashrc.d"
    mkdir -p "$TEST_TEMP_DIR/etc/bash_completion.d"
    mkdir -p "$TEST_TEMP_DIR/usr/local/bin"
}

# Teardown function - runs after each test
teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
}

# Helper to create mock completion script
create_mock_completion() {
    local name="$1"
    local func_name="${2:-_${name}}"

    command cat > "$TEST_TEMP_DIR/etc/bash_completion.d/$name" << EOF
# Mock completion for $name
$func_name() {
    local cur="\${COMP_WORDS[COMP_CWORD]}"
    COMPREPLY=( \$(compgen -W "get create delete describe" -- "\$cur") )
}
complete -F $func_name $name
EOF
}

# Test: Completion script can be sourced without errors
test_completion_sourcing() {
    create_mock_completion "kubectl"

    # Try to source in a subshell to catch errors
    if bash -c "source '$TEST_TEMP_DIR/etc/bash_completion.d/kubectl'" 2>/dev/null; then
        assert_true true "Completion script sources without errors"
    else
        assert_true false "Completion script failed to source"
    fi
}

# Test: Completion function is defined after sourcing
test_completion_function_defined() {
    create_mock_completion "helm" "_helm_completion"

    # Check function is defined after sourcing
    local result
    result=$(bash -c "
        source '$TEST_TEMP_DIR/etc/bash_completion.d/helm'
        type -t _helm_completion
    " 2>/dev/null || echo "not found")

    if [ "$result" = "function" ]; then
        assert_true true "Completion function is defined"
    else
        assert_true false "Completion function not defined: $result"
    fi
}

# Test: Bashrc.d scripts are valid shell syntax
test_bashrc_script_syntax() {
    # Create a mock bashrc.d script
    command cat > "$TEST_TEMP_DIR/etc/bashrc.d/50-test-completion.sh" << 'EOF'
#!/bin/bash
# Test completion setup

if command -v mycommand &> /dev/null; then
    # Generate completion
    eval "$(mycommand completion bash 2>/dev/null || true)"
fi
EOF

    # Check syntax
    if bash -n "$TEST_TEMP_DIR/etc/bashrc.d/50-test-completion.sh" 2>/dev/null; then
        assert_true true "Bashrc script has valid syntax"
    else
        assert_true false "Bashrc script has syntax errors"
    fi
}

# Test: Completion script validation (size check)
test_completion_size_validation() {
    create_mock_completion "test-tool"

    local file="$TEST_TEMP_DIR/etc/bash_completion.d/test-tool"
    local size
    size=$(wc -c < "$file")

    # Check size is reasonable (less than 100KB)
    if [ "$size" -lt 100000 ]; then
        assert_true true "Completion script size is reasonable: $size bytes"
    else
        assert_true false "Completion script too large: $size bytes"
    fi
}

# Test: Completion script security validation
test_completion_security_validation() {
    create_mock_completion "safe-tool"

    local file="$TEST_TEMP_DIR/etc/bash_completion.d/safe-tool"

    # Check for dangerous patterns
    if grep -qE '(rm -rf|curl.*bash|wget.*bash|eval.*\$)' "$file"; then
        assert_true false "Completion script contains dangerous patterns"
    else
        assert_true true "Completion script passes security check"
    fi
}

# Test: Multiple completions can be loaded together
test_multiple_completions() {
    create_mock_completion "tool1" "_tool1"
    create_mock_completion "tool2" "_tool2"
    create_mock_completion "tool3" "_tool3"

    # Source all in same shell
    local result
    result=$(bash -c "
        source '$TEST_TEMP_DIR/etc/bash_completion.d/tool1'
        source '$TEST_TEMP_DIR/etc/bash_completion.d/tool2'
        source '$TEST_TEMP_DIR/etc/bash_completion.d/tool3'
        echo \$(type -t _tool1)-\$(type -t _tool2)-\$(type -t _tool3)
    " 2>/dev/null || echo "error")

    if [ "$result" = "function-function-function" ]; then
        assert_true true "Multiple completions load without conflict"
    else
        assert_true false "Multiple completions failed: $result"
    fi
}

# Test: Dynamic completion generation
test_dynamic_completion() {
    # Simulate kubectl completion bash pattern
    local mock_output="$TEST_TEMP_DIR/completion-output.bash"

    # Create a mock tool that outputs completion
    command cat > "$TEST_TEMP_DIR/usr/local/bin/mock-tool" << 'EOF'
#!/bin/bash
if [ "$1" = "completion" ] && [ "$2" = "bash" ]; then
    echo '_mock_tool() { COMPREPLY=(test); }; complete -F _mock_tool mock-tool'
fi
EOF
    chmod +x "$TEST_TEMP_DIR/usr/local/bin/mock-tool"

    # Generate and source completion
    "$TEST_TEMP_DIR/usr/local/bin/mock-tool" completion bash > "$mock_output"

    local result
    result=$(bash -c "
        source '$mock_output'
        type -t _mock_tool
    " 2>/dev/null || echo "not found")

    if [ "$result" = "function" ]; then
        assert_true true "Dynamic completion generation works"
    else
        assert_true false "Dynamic completion failed: $result"
    fi
}

# Test: Completion with alias support
test_completion_with_aliases() {
    # Create completion that supports aliases
    command cat > "$TEST_TEMP_DIR/etc/bash_completion.d/kubectl" << 'EOF'
_kubectl() {
    COMPREPLY=(get create delete)
}
complete -F _kubectl kubectl
complete -F _kubectl k
EOF

    # Check both kubectl and alias 'k' get completion
    local result
    result=$(bash -c "
        source '$TEST_TEMP_DIR/etc/bash_completion.d/kubectl'
        complete -p k kubectl 2>&1 | wc -l
    " 2>/dev/null || echo "0")

    if [ "$result" -eq 2 ]; then
        assert_true true "Completion works for command and alias"
    else
        assert_true false "Alias completion not set up: $result lines"
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
run_test_with_setup test_completion_sourcing "Completion scripts can be sourced"
run_test_with_setup test_completion_function_defined "Completion functions are defined"
run_test_with_setup test_bashrc_script_syntax "Bashrc.d scripts have valid syntax"
run_test_with_setup test_completion_size_validation "Completion scripts have reasonable size"
run_test_with_setup test_completion_security_validation "Completion scripts pass security check"
run_test_with_setup test_multiple_completions "Multiple completions load together"
run_test_with_setup test_dynamic_completion "Dynamic completion generation works"
run_test_with_setup test_completion_with_aliases "Completion works with aliases"

# Generate test report
generate_report
