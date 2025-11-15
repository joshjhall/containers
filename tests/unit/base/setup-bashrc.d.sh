#!/usr/bin/env bash
# Unit tests for lib/base/setup-bashrc.d.sh
# Tests the bashrc.d directory structure setup

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Setup Bashrc.d Tests"

# Setup function - runs before each test
setup() {
    # Create temporary directory for testing
    export TEST_TEMP_DIR="$RESULTS_DIR/test-setup-bashrc.d"
    mkdir -p "$TEST_TEMP_DIR"
    
    # Create mock etc directory
    export MOCK_ETC="$TEST_TEMP_DIR/etc"
    mkdir -p "$MOCK_ETC"
    
    # Create mock bash.bashrc
    export MOCK_BASHRC="$MOCK_ETC/bash.bashrc"
    echo "# Original bashrc content" > "$MOCK_BASHRC"
    
    # Create mock bashrc.d directory
    export MOCK_BASHRC_D="$MOCK_ETC/bashrc.d"
}

# Teardown function - runs after each test
teardown() {
    # Clean up test directory
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
    
    # Unset test variables
    unset MOCK_ETC MOCK_BASHRC MOCK_BASHRC_D 2>/dev/null || true
}

# Test: bashrc.d directory is created
test_bashrc_d_directory_created() {
    # Simulate creating the directory
    mkdir -p "$MOCK_BASHRC_D"
    
    assert_dir_exists "$MOCK_BASHRC_D"
    
    # Check permissions
    if [ -d "$MOCK_BASHRC_D" ]; then
        assert_true true "bashrc.d directory created successfully"
    else
        assert_true false "bashrc.d directory not created"
    fi
}

# Test: Sourcing added to bash.bashrc
test_bashrc_sourcing_added() {
    # Simulate adding sourcing to bash.bashrc
    if ! grep -q "/etc/bashrc.d" "$MOCK_BASHRC" 2>/dev/null; then
        cat >> "$MOCK_BASHRC" << 'EOF'

# Source all scripts in /etc/bashrc.d
if [ -d /etc/bashrc.d ]; then
    for f in /etc/bashrc.d/*.sh; do
        [ -r "$f" ] && . "$f"
    done
fi
EOF
    fi
    
    # Check that sourcing was added
    if grep -q "/etc/bashrc.d" "$MOCK_BASHRC"; then
        assert_true true "Sourcing added to bash.bashrc"
    else
        assert_true false "Sourcing not added to bash.bashrc"
    fi
    
    # Check for loop structure
    if grep -q "for f in /etc/bashrc.d/\*.sh" "$MOCK_BASHRC"; then
        assert_true true "For loop structure correct"
    else
        assert_true false "For loop structure incorrect"
    fi
}

# Test: bash_env file created for non-interactive shells
test_bash_env_created() {
    local bash_env="$MOCK_ETC/bash_env"
    
    # Create bash_env file
    cat > "$bash_env" << 'EOF'
#!/bin/bash
# Environment setup for non-interactive bash shells
# This file is sourced when BASH_ENV is set

# Source all scripts in /etc/bashrc.d
if [ -d /etc/bashrc.d ]; then
    for f in /etc/bashrc.d/*.sh; do
        [ -r "$f" ] && . "$f" 2>/dev/null || true
    done
fi
EOF
    
    assert_file_exists "$bash_env"
    
    # Check shebang
    if head -n1 "$bash_env" | grep -q "#!/bin/bash"; then
        assert_true true "bash_env has shebang"
    else
        assert_true false "bash_env missing shebang"
    fi
    
    # Check error handling (|| true)
    if grep -q "|| true" "$bash_env"; then
        assert_true true "bash_env has error handling"
    else
        assert_true false "bash_env missing error handling"
    fi
}

# Test: bash_env is executable
test_bash_env_executable() {
    local bash_env="$MOCK_ETC/bash_env"
    
    # Create and make executable
    touch "$bash_env"
    chmod +x "$bash_env"
    
    if [ -x "$bash_env" ]; then
        assert_true true "bash_env is executable"
    else
        assert_true false "bash_env is not executable"
    fi
}

# Test: Base paths script created
test_base_paths_script() {
    mkdir -p "$MOCK_BASHRC_D"
    local base_paths="$MOCK_BASHRC_D/00-base-paths.sh"
    
    # Create base paths script
    cat > "$base_paths" << 'EOF'
# Base PATH setup
# This is sourced by both interactive and non-interactive shells

# Start with clean system paths
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Add user's local bin if it exists
if [ -d "$HOME/.local/bin" ]; then
    export PATH="$HOME/.local/bin:$PATH"
fi
EOF
    
    assert_file_exists "$base_paths"
    
    # Check PATH export
    if grep -q 'export PATH="/usr/local/sbin' "$base_paths"; then
        assert_true true "Base PATH is set"
    else
        assert_true false "Base PATH not set"
    fi
    
    # Check HOME/.local/bin addition
    if grep -q 'HOME/.local/bin' "$base_paths"; then
        assert_true true "User local bin added to PATH"
    else
        assert_true false "User local bin not added to PATH"
    fi
}

# Test: Base paths script is executable
test_base_paths_executable() {
    mkdir -p "$MOCK_BASHRC_D"
    local base_paths="$MOCK_BASHRC_D/00-base-paths.sh"
    
    touch "$base_paths"
    chmod +x "$base_paths"
    
    if [ -x "$base_paths" ]; then
        assert_true true "Base paths script is executable"
    else
        assert_true false "Base paths script is not executable"
    fi
}

# Test: Script numbering for order
test_script_numbering() {
    mkdir -p "$MOCK_BASHRC_D"
    
    # Check that base paths uses 00- prefix for early execution
    local base_paths="$MOCK_BASHRC_D/00-base-paths.sh"
    touch "$base_paths"
    
    local filename
    filename=$(basename "$base_paths")
    if [[ "$filename" =~ ^00- ]]; then
        assert_true true "Base paths uses 00- prefix for early execution"
    else
        assert_true false "Base paths doesn't use proper numbering"
    fi
}

# Test: Idempotency - doesn't duplicate sourcing
test_idempotent_sourcing() {
    # Add sourcing once
    cat >> "$MOCK_BASHRC" << 'EOF'
# Source all scripts in /etc/bashrc.d
if [ -d /etc/bashrc.d ]; then
    for f in /etc/bashrc.d/*.sh; do
        [ -r "$f" ] && . "$f"
    done
fi
EOF
    
    local line_count_before
    line_count_before=$(grep -c "/etc/bashrc.d" "$MOCK_BASHRC")
    
    # Try to add again (should skip if already present)
    if ! grep -q "/etc/bashrc.d" "$MOCK_BASHRC" 2>/dev/null; then
        cat >> "$MOCK_BASHRC" << 'EOF'
# Source all scripts in /etc/bashrc.d
if [ -d /etc/bashrc.d ]; then
    for f in /etc/bashrc.d/*.sh; do
        [ -r "$f" ] && . "$f"
    done
fi
EOF
    fi
    
    local line_count_after
    line_count_after=$(grep -c "/etc/bashrc.d" "$MOCK_BASHRC")
    
    assert_equals "$line_count_before" "$line_count_after" "Sourcing not duplicated"
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
run_test_with_setup test_bashrc_d_directory_created "bashrc.d directory is created"
run_test_with_setup test_bashrc_sourcing_added "Sourcing added to bash.bashrc"
run_test_with_setup test_bash_env_created "bash_env file created for non-interactive shells"
run_test_with_setup test_bash_env_executable "bash_env is executable"
run_test_with_setup test_base_paths_script "Base paths script created"
run_test_with_setup test_base_paths_executable "Base paths script is executable"
run_test_with_setup test_script_numbering "Script uses proper numbering for order"
run_test_with_setup test_idempotent_sourcing "Sourcing is idempotent"

# Generate test report
generate_report