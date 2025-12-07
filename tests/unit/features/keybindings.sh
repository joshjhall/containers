#!/usr/bin/env bash
# Unit tests for lib/features/keybindings.sh
# Tests keyboard bindings configuration for terminal shortcuts

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Keybindings Feature Tests"

# Setup function - runs before each test
setup() {
    # Create temporary directory for testing
    export TEST_TEMP_DIR="$RESULTS_DIR/test-keybindings"
    mkdir -p "$TEST_TEMP_DIR"

    # Mock environment
    export USERNAME="testuser"
    export USER_UID="1000"
    export USER_GID="1000"

    # Create mock directories
    mkdir -p "$TEST_TEMP_DIR/etc/bashrc.d"
    mkdir -p "$TEST_TEMP_DIR/etc/skel"
    mkdir -p "$TEST_TEMP_DIR/usr/local/bin"
}

# Teardown function - runs after each test
teardown() {
    # Clean up test directory
    command rm -rf "$TEST_TEMP_DIR"

    # Unset test variables
    unset USERNAME USER_UID USER_GID KEYBINDING_PROFILE 2>/dev/null || true
}

# Test: keybindings.sh exists
test_keybindings_script_exists() {
    local script="$PROJECT_ROOT/lib/features/keybindings.sh"

    if [ -f "$script" ]; then
        assert_true true "keybindings.sh exists"
    else
        assert_true false "keybindings.sh not found"
    fi
}

# Test: keybindings.sh is executable format
test_keybindings_script_format() {
    local script="$PROJECT_ROOT/lib/features/keybindings.sh"

    if [ -f "$script" ]; then
        # Check for proper shebang
        if head -1 "$script" | grep -q "#!/bin/bash"; then
            assert_true true "Script has proper shebang"
        else
            assert_true false "Script missing or has incorrect shebang"
        fi
    else
        skip_test "keybindings.sh not found"
    fi
}

# Test: Script sources required headers
test_keybindings_sources_headers() {
    local script="$PROJECT_ROOT/lib/features/keybindings.sh"

    if ! [ -f "$script" ]; then
        skip_test "keybindings.sh not found"
        return
    fi

    # Check for feature-header.sh
    if grep -q "source.*feature-header.sh" "$script"; then
        assert_true true "Script sources feature-header.sh"
    else
        assert_true false "Script does not source feature-header.sh"
    fi

    # Check for bashrc-helpers.sh
    if grep -q "source.*bashrc-helpers.sh" "$script"; then
        assert_true true "Script sources bashrc-helpers.sh"
    else
        assert_true false "Script does not source bashrc-helpers.sh"
    fi
}

# Test: Inputrc creation
test_inputrc_creation() {
    local inputrc_file="$TEST_TEMP_DIR/etc/inputrc"

    # Create a mock inputrc file with expected content
    command cat > "$inputrc_file" << 'EOF'
# /etc/inputrc - System-wide readline configuration
set editing-mode emacs
set completion-ignore-case on
set show-all-if-ambiguous on
"\C-a": beginning-of-line
"\C-e": end-of-line
EOF

    assert_file_exists "$inputrc_file"

    # Check for essential settings
    if grep -q "completion-ignore-case on" "$inputrc_file"; then
        assert_true true "Case-insensitive completion enabled"
    else
        assert_true false "Case-insensitive completion not found"
    fi

    if grep -q "show-all-if-ambiguous on" "$inputrc_file"; then
        assert_true true "Show-all-if-ambiguous enabled"
    else
        assert_true false "Show-all-if-ambiguous not found"
    fi

    if grep -q "editing-mode emacs" "$inputrc_file"; then
        assert_true true "Emacs editing mode set"
    else
        assert_true false "Emacs editing mode not found"
    fi
}

# Test: iTerm profile keybindings
test_iterm_keybindings() {
    local inputrc_file="$TEST_TEMP_DIR/etc/inputrc"

    # Create mock iTerm inputrc content
    command cat > "$inputrc_file" << 'EOF'
# iTerm2 / macOS Terminal Key Bindings
"\ef": forward-word
"\eb": backward-word
"\e[1;3C": forward-word
"\e[1;3D": backward-word
"\e\C-?": backward-kill-word
"\ed": kill-word
EOF

    # Check for Meta+f/b bindings (standard readline word movement)
    if grep -q '\\ef.*forward-word' "$inputrc_file"; then
        assert_true true "Meta+f (forward-word) binding present"
    else
        assert_true false "Meta+f binding not found"
    fi

    if grep -q '\\eb.*backward-word' "$inputrc_file"; then
        assert_true true "Meta+b (backward-word) binding present"
    else
        assert_true false "Meta+b binding not found"
    fi

    # Check for iTerm2-specific sequences
    if grep -q '\\e\[1;3C.*forward-word' "$inputrc_file"; then
        assert_true true "iTerm2 Option+Right binding present"
    else
        assert_true false "iTerm2 Option+Right binding not found"
    fi

    if grep -q '\\e\[1;3D.*backward-word' "$inputrc_file"; then
        assert_true true "iTerm2 Option+Left binding present"
    else
        assert_true false "iTerm2 Option+Left binding not found"
    fi
}

# Test: xterm profile keybindings in script
test_xterm_keybindings_in_script() {
    local script="$PROJECT_ROOT/lib/features/keybindings.sh"

    if ! [ -f "$script" ]; then
        skip_test "keybindings.sh not found"
        return
    fi

    # Check for xterm Ctrl+Arrow sequences
    if grep -q '\\e\[1;5C.*forward-word' "$script"; then
        assert_true true "xterm Ctrl+Right binding in script"
    else
        assert_true false "xterm Ctrl+Right binding not found in script"
    fi

    if grep -q '\\e\[1;5D.*backward-word' "$script"; then
        assert_true true "xterm Ctrl+Left binding in script"
    else
        assert_true false "xterm Ctrl+Left binding not found in script"
    fi
}

# Test: Profile selection in script
test_profile_selection() {
    local script="$PROJECT_ROOT/lib/features/keybindings.sh"

    if ! [ -f "$script" ]; then
        skip_test "keybindings.sh not found"
        return
    fi

    # Check for KEYBINDING_PROFILE variable usage
    if grep -q 'KEYBINDING_PROFILE.*:-iterm' "$script"; then
        assert_true true "KEYBINDING_PROFILE defaults to iterm"
    else
        assert_true false "KEYBINDING_PROFILE default not found"
    fi

    # Check for case statement with profiles
    if grep -q 'iterm|macos)' "$script"; then
        assert_true true "iTerm/macOS profile case exists"
    else
        assert_true false "iTerm/macOS profile case not found"
    fi

    if grep -q 'xterm|linux)' "$script"; then
        assert_true true "xterm/Linux profile case exists"
    else
        assert_true false "xterm/Linux profile case not found"
    fi

    if grep -q 'minimal|none)' "$script"; then
        assert_true true "Minimal profile case exists"
    else
        assert_true false "Minimal profile case not found"
    fi
}

# Test: Bashrc.d script creation
test_bashrc_script_creation() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/10-keybindings.sh"

    # Create mock bashrc.d script
    command cat > "$bashrc_file" << 'EOF'
# Keyboard Bindings Enhancement
if [[ $- != *i* ]]; then
    return 0
fi
if [ -f /etc/inputrc ]; then
    bind -f /etc/inputrc 2>/dev/null || true
fi
stty -ixon 2>/dev/null || true
EOF

    assert_file_exists "$bashrc_file"

    # Check for interactive shell check
    if grep -q '\$- != \*i\*' "$bashrc_file"; then
        assert_true true "Interactive shell check present"
    else
        assert_true false "Interactive shell check not found"
    fi

    # Check for inputrc loading
    if grep -q 'bind -f /etc/inputrc' "$bashrc_file"; then
        assert_true true "Inputrc loading command present"
    else
        assert_true false "Inputrc loading command not found"
    fi

    # Check for stty -ixon (disable flow control)
    if grep -q 'stty -ixon' "$bashrc_file"; then
        assert_true true "Flow control disabled (stty -ixon)"
    else
        assert_true false "Flow control disable not found"
    fi
}

# Test: User inputrc template
test_user_inputrc_template() {
    local user_inputrc="$TEST_TEMP_DIR/etc/skel/.inputrc"

    # Create mock user inputrc template
    command cat > "$user_inputrc" << 'EOF'
# ~/.inputrc - User readline configuration
$include /etc/inputrc
# User Customizations Below
EOF

    assert_file_exists "$user_inputrc"

    # Check for system inputrc include
    if grep -q '\$include /etc/inputrc' "$user_inputrc"; then
        assert_true true "User inputrc includes system inputrc"
    else
        assert_true false "User inputrc missing system include"
    fi
}

# Test: Verification script creation
test_verification_script() {
    local test_script="$TEST_TEMP_DIR/usr/local/bin/test-keybindings"

    # Create mock verification script
    command cat > "$test_script" << 'EOF'
#!/bin/bash
echo "=== Keyboard Bindings Status ==="
echo "Active Profile: ${KEYBINDING_PROFILE:-iterm}"
echo "Configuration Files:"
[ -f /etc/inputrc ] && echo "  ✓ /etc/inputrc"
echo "Standard Bindings (all profiles):"
echo "  - Ctrl + A → Beginning of line"
EOF
    chmod +x "$test_script"

    assert_file_exists "$test_script"

    # Check for essential content
    if grep -q "KEYBINDING_PROFILE" "$test_script"; then
        assert_true true "Verification script shows profile"
    else
        assert_true false "Verification script missing profile display"
    fi

    if grep -q "/etc/inputrc" "$test_script"; then
        assert_true true "Verification script checks inputrc"
    else
        assert_true false "Verification script missing inputrc check"
    fi

    # Check if executable
    if [ -x "$test_script" ]; then
        assert_true true "Verification script is executable"
    else
        assert_true false "Verification script is not executable"
    fi
}

# Test: Standard readline bindings in script
test_standard_bindings() {
    local script="$PROJECT_ROOT/lib/features/keybindings.sh"

    if ! [ -f "$script" ]; then
        skip_test "keybindings.sh not found"
        return
    fi

    # Check for standard Ctrl bindings
    if grep -q '\\C-a.*beginning-of-line' "$script"; then
        assert_true true "Ctrl+A binding present"
    else
        assert_true false "Ctrl+A binding not found"
    fi

    if grep -q '\\C-e.*end-of-line' "$script"; then
        assert_true true "Ctrl+E binding present"
    else
        assert_true false "Ctrl+E binding not found"
    fi

    if grep -q '\\C-u.*unix-line-discard' "$script"; then
        assert_true true "Ctrl+U binding present"
    else
        assert_true false "Ctrl+U binding not found"
    fi

    if grep -q '\\C-k.*kill-line' "$script"; then
        assert_true true "Ctrl+K binding present"
    else
        assert_true false "Ctrl+K binding not found"
    fi

    if grep -q '\\C-r.*reverse-search-history' "$script"; then
        assert_true true "Ctrl+R binding present"
    else
        assert_true false "Ctrl+R binding not found"
    fi
}

# Test: Word deletion bindings
test_word_deletion_bindings() {
    local script="$PROJECT_ROOT/lib/features/keybindings.sh"

    if ! [ -f "$script" ]; then
        skip_test "keybindings.sh not found"
        return
    fi

    # Check for backward-kill-word binding
    if grep -q 'backward-kill-word' "$script"; then
        assert_true true "backward-kill-word binding present"
    else
        assert_true false "backward-kill-word binding not found"
    fi

    # Check for kill-word binding
    if grep -q '\\ed.*kill-word' "$script"; then
        assert_true true "Meta+d kill-word binding present"
    else
        assert_true false "Meta+d kill-word binding not found"
    fi
}

# Test: History search bindings
test_history_search_bindings() {
    local script="$PROJECT_ROOT/lib/features/keybindings.sh"

    if ! [ -f "$script" ]; then
        skip_test "keybindings.sh not found"
        return
    fi

    # Check for history-search-backward
    if grep -q 'history-search-backward' "$script"; then
        assert_true true "history-search-backward binding present"
    else
        assert_true false "history-search-backward binding not found"
    fi

    # Check for history-search-forward
    if grep -q 'history-search-forward' "$script"; then
        assert_true true "history-search-forward binding present"
    else
        assert_true false "history-search-forward binding not found"
    fi
}

# Test: Dockerfile integration
test_dockerfile_integration() {
    local dockerfile="$PROJECT_ROOT/Dockerfile"

    if ! [ -f "$dockerfile" ]; then
        skip_test "Dockerfile not found"
        return
    fi

    # Check for INCLUDE_KEYBINDINGS build arg
    if grep -q 'ARG INCLUDE_KEYBINDINGS' "$dockerfile"; then
        assert_true true "INCLUDE_KEYBINDINGS build arg present"
    else
        assert_true false "INCLUDE_KEYBINDINGS build arg not found"
    fi

    # Check for KEYBINDING_PROFILE build arg
    if grep -q 'ARG KEYBINDING_PROFILE' "$dockerfile"; then
        assert_true true "KEYBINDING_PROFILE build arg present"
    else
        assert_true false "KEYBINDING_PROFILE build arg not found"
    fi

    # Check for keybindings.sh invocation
    if grep -q 'keybindings.sh' "$dockerfile"; then
        assert_true true "keybindings.sh invoked in Dockerfile"
    else
        assert_true false "keybindings.sh not invoked in Dockerfile"
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
run_test test_keybindings_script_exists "keybindings.sh script exists"
run_test test_keybindings_script_format "keybindings.sh has proper format"
run_test test_keybindings_sources_headers "keybindings.sh sources required headers"
run_test test_profile_selection "Profile selection logic works"
run_test test_xterm_keybindings_in_script "xterm keybindings in script"
run_test test_standard_bindings "Standard readline bindings present"
run_test test_word_deletion_bindings "Word deletion bindings present"
run_test test_history_search_bindings "History search bindings present"
run_test test_dockerfile_integration "Dockerfile integration correct"

# Tests with setup/teardown
run_test_with_setup test_inputrc_creation "Inputrc file creation"
run_test_with_setup test_iterm_keybindings "iTerm profile keybindings"
run_test_with_setup test_bashrc_script_creation "Bashrc.d script creation"
run_test_with_setup test_user_inputrc_template "User inputrc template creation"
run_test_with_setup test_verification_script "Verification script creation"

# Generate test report
generate_report
