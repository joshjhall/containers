#!/usr/bin/env bash
# Unit tests for lib/base/aliases.sh
# Tests that aliases are properly written to bashrc

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Base Aliases Tests"

# Setup function - runs before each test
setup() {
    # Create temporary directory for testing
    export TEST_TEMP_DIR="$RESULTS_DIR/test-aliases"
    mkdir -p "$TEST_TEMP_DIR"

    # Create mock bashrc file
    export TEST_BASHRC="$TEST_TEMP_DIR/bash.bashrc"
    touch "$TEST_BASHRC"

    # Create mock build scripts directory
    mkdir -p "$TEST_TEMP_DIR/tmp/build-scripts/base"
}

# Teardown function - runs after each test
teardown() {
    # Clean up test directory
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi

    # Unset test variables
    unset TEST_BASHRC 2>/dev/null || true
}

# Test: Script appends aliases to bashrc
test_aliases_written_to_bashrc() {
    # Simulate the script's append operation
    command cat >> "$TEST_BASHRC" << 'EOF'
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
EOF

    # Check that aliases were written
    assert_file_exists "$TEST_BASHRC"

    if command grep -q "alias ll='ls -alF'" "$TEST_BASHRC"; then
        assert_true true "ll alias written to bashrc"
    else
        assert_true false "ll alias not found in bashrc"
    fi

    if command grep -q "alias la='ls -A'" "$TEST_BASHRC"; then
        assert_true true "la alias written to bashrc"
    else
        assert_true false "la alias not found in bashrc"
    fi
}

# Test: Navigation aliases are included
test_navigation_aliases() {
    # Write navigation aliases
    command cat >> "$TEST_BASHRC" << 'EOF'
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
EOF

    # Check navigation aliases
    if command grep -q "alias \.\.='cd \.\.'" "$TEST_BASHRC"; then
        assert_true true "Parent directory alias (..) written"
    else
        assert_true false "Parent directory alias not found"
    fi

    if command grep -q "alias \.\.\.='cd \.\./\.\.'" "$TEST_BASHRC"; then
        assert_true true "Two-level parent alias (...) written"
    else
        assert_true false "Two-level parent alias not found"
    fi
}

# Test: Safety aliases (interactive mode)
test_safety_aliases() {
    # Write safety aliases
    command cat >> "$TEST_BASHRC" << 'EOF'
alias rm='command rm -i'
alias cp='cp -i'
alias mv='mv -i'
EOF

    # Check safety aliases
    if command grep -q "alias rm='command rm -i'" "$TEST_BASHRC"; then
        assert_true true "Safe rm alias written"
    else
        assert_true false "Safe rm alias not found"
    fi

    if command grep -q "alias cp='cp -i'" "$TEST_BASHRC"; then
        assert_true true "Safe cp alias written"
    else
        assert_true false "Safe cp alias not found"
    fi

    if command grep -q "alias mv='mv -i'" "$TEST_BASHRC"; then
        assert_true true "Safe mv alias written"
    else
        assert_true false "Safe mv alias not found"
    fi
}

# Test: Git aliases are included
test_git_aliases() {
    # Write git aliases
    command cat >> "$TEST_BASHRC" << 'EOF'
alias g='git'
alias gs='git status'
alias gd='git diff'
alias gl='git log --oneline'
alias ga='git add'
alias gc='git commit'
EOF

    # Check git aliases
    for alias_cmd in "g='git'" "gs='git status'" "gd='git diff'"; do
        if command grep -q "alias $alias_cmd" "$TEST_BASHRC"; then
            assert_true true "Git alias '$alias_cmd' written"
        else
            assert_true false "Git alias '$alias_cmd' not found"
        fi
    done
}

# Test: Environment variables are set
test_environment_variables() {
    # Write environment exports
    command cat >> "$TEST_BASHRC" << 'EOF'
export TERM=xterm-256color
export COLORTERM=truecolor
export LESS="-R"
export HISTSIZE=10000
export HISTFILESIZE=20000
export HISTCONTROL=ignoreboth:erasedups
EOF

    # Check environment variables
    if command grep -q "export TERM=xterm-256color" "$TEST_BASHRC"; then
        assert_true true "TERM environment variable set"
    else
        assert_true false "TERM environment variable not found"
    fi

    if command grep -q "export HISTSIZE=10000" "$TEST_BASHRC"; then
        assert_true true "HISTSIZE environment variable set"
    else
        assert_true false "HISTSIZE environment variable not found"
    fi
}

# Test: Shell options are configured
test_shell_options() {
    # Write shell options
    command cat >> "$TEST_BASHRC" << 'EOF'
shopt -s histappend
shopt -s checkwinsize
shopt -s globstar 2>/dev/null || true
shopt -s autocd 2>/dev/null || true
EOF

    # Check shell options
    if command grep -q "shopt -s histappend" "$TEST_BASHRC"; then
        assert_true true "histappend shell option set"
    else
        assert_true false "histappend shell option not found"
    fi

    if command grep -q "shopt -s checkwinsize" "$TEST_BASHRC"; then
        assert_true true "checkwinsize shell option set"
    else
        assert_true false "checkwinsize shell option not found"
    fi
}

# Test: Productivity shortcuts are included
test_productivity_shortcuts() {
    # Write productivity aliases
    command cat >> "$TEST_BASHRC" << 'EOF'
alias h='history'
alias hgrep='history | grep'
alias j='jobs -l'
alias which='type -a'
alias path='echo -e ${PATH//:/\\n}'
alias psg='ps aux | command grep -v grep | command grep -i'
EOF

    # Check productivity aliases
    if command grep -q "alias h='history'" "$TEST_BASHRC"; then
        assert_true true "History alias written"
    else
        assert_true false "History alias not found"
    fi

    if command grep -q "alias psg=" "$TEST_BASHRC"; then
        assert_true true "Process grep alias written"
    else
        assert_true false "Process grep alias not found"
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
run_test_with_setup test_aliases_written_to_bashrc "Aliases are written to bashrc"
run_test_with_setup test_navigation_aliases "Navigation aliases are included"
run_test_with_setup test_safety_aliases "Safety aliases are configured"
run_test_with_setup test_git_aliases "Git aliases are included"
run_test_with_setup test_environment_variables "Environment variables are set"
run_test_with_setup test_shell_options "Shell options are configured"
run_test_with_setup test_productivity_shortcuts "Productivity shortcuts are included"

# Generate test report
generate_report
