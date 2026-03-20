#!/usr/bin/env bash
# Unit tests for bin/lib/release/git-cliff.sh

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Release Git Cliff Tests"

# Helper to set up color vars expected by git-cliff.sh
setup_cliff_env() {
    RED="" GREEN="" BLUE="" YELLOW="" NC=""
    export RED GREEN BLUE YELLOW NC
}

# ============================================================================
# Test: ensure_git_cliff when already installed
# ============================================================================
test_ensure_git_cliff_already_installed() {
    setup_cliff_env

    source "$PROJECT_ROOT/bin/lib/release/git-cliff.sh"

    # Create a mock git-cliff in PATH
    local mock_bin="$TEST_TEMP_DIR/bin"
    mkdir -p "$mock_bin"
    echo '#!/bin/bash' > "$mock_bin/git-cliff"
    echo 'echo "git-cliff 2.8.0"' >> "$mock_bin/git-cliff"
    chmod +x "$mock_bin/git-cliff"

    # Run with mock in PATH
    local exit_code=0
    PATH="$mock_bin:$PATH" ensure_git_cliff 2>/dev/null || exit_code=$?

    assert_equals "0" "$exit_code" "Returns 0 when git-cliff already in PATH"
}

# ============================================================================
# Test: ensure_git_cliff tries cargo install when cargo available
# ============================================================================
test_ensure_git_cliff_installs_via_cargo() {
    setup_cliff_env

    source "$PROJECT_ROOT/bin/lib/release/git-cliff.sh"

    # Create mock cargo and ensure no git-cliff in PATH
    local mock_bin="$TEST_TEMP_DIR/bin"
    mkdir -p "$mock_bin"
    echo '#!/bin/bash' > "$mock_bin/cargo"
    echo 'echo "CARGO_INSTALL_CALLED $@" > '"$TEST_TEMP_DIR/cargo_log"'' >> "$mock_bin/cargo"
    chmod +x "$mock_bin/cargo"

    # Run with mock cargo and no git-cliff
    PATH="$mock_bin" ensure_git_cliff 2>/dev/null || true

    if [ -f "$TEST_TEMP_DIR/cargo_log" ]; then
        local log_content
        log_content=$(/usr/bin/cat "$TEST_TEMP_DIR/cargo_log")
        assert_contains "$log_content" "CARGO_INSTALL_CALLED install git-cliff" \
            "Calls cargo install git-cliff"
    else
        assert_true false "cargo was not called"
    fi
}

# ============================================================================
# Test: Download URL construction for linux x86_64
# ============================================================================
test_ensure_git_cliff_linux_x86_url() {
    local script_content
    script_content=$(/usr/bin/cat "$PROJECT_ROOT/bin/lib/release/git-cliff.sh")

    # Verify the URL template uses correct platform mappings
    assert_contains "$script_content" 'unknown-linux-gnu' \
        "Script maps linux to unknown-linux-gnu"
    assert_contains "$script_content" 'x86_64) arch="x86_64"' \
        "Script maps x86_64 architecture"
}

# ============================================================================
# Test: Download URL construction for darwin arm64
# ============================================================================
test_ensure_git_cliff_darwin_arm_url() {
    local script_content
    script_content=$(/usr/bin/cat "$PROJECT_ROOT/bin/lib/release/git-cliff.sh")

    assert_contains "$script_content" 'apple-darwin' \
        "Script maps darwin to apple-darwin"
    assert_contains "$script_content" 'aarch64|arm64) arch="aarch64"' \
        "Script maps arm64 to aarch64"
}

# ============================================================================
# Test: Unsupported architecture returns 1
# ============================================================================
test_ensure_git_cliff_unsupported_arch() {
    setup_cliff_env

    source "$PROJECT_ROOT/bin/lib/release/git-cliff.sh"

    # Override uname to return unsupported arch, and ensure no git-cliff or cargo
    local exit_code=0
    (
        uname() {
            if [ "${1:-}" = "-s" ]; then
                echo "Linux"
            elif [ "${1:-}" = "-m" ]; then
                echo "s390x"
            fi
        }
        # Use empty PATH with only basic commands
        PATH="" ensure_git_cliff 2>/dev/null
    ) || exit_code=$?

    assert_not_equals "0" "$exit_code" "Returns non-zero for unsupported architecture"
}

# ============================================================================
# Test: Unsupported OS returns 1
# ============================================================================
test_ensure_git_cliff_unsupported_os() {
    setup_cliff_env

    source "$PROJECT_ROOT/bin/lib/release/git-cliff.sh"

    local exit_code=0
    (
        uname() {
            if [ "${1:-}" = "-s" ]; then
                echo "FreeBSD"
            elif [ "${1:-}" = "-m" ]; then
                echo "x86_64"
            fi
        }
        PATH="" ensure_git_cliff 2>/dev/null
    ) || exit_code=$?

    assert_not_equals "0" "$exit_code" "Returns non-zero for unsupported OS"
}

# ============================================================================
# Test: Download failure returns 1
# ============================================================================
test_ensure_git_cliff_download_failure() {
    setup_cliff_env

    source "$PROJECT_ROOT/bin/lib/release/git-cliff.sh"

    # Create mock curl that always fails, and mock uname for valid platform
    local mock_bin="$TEST_TEMP_DIR/bin"
    mkdir -p "$mock_bin"

    echo '#!/bin/bash' > "$mock_bin/curl"
    echo 'exit 1' >> "$mock_bin/curl"
    chmod +x "$mock_bin/curl"

    echo '#!/bin/bash' > "$mock_bin/uname"
    /usr/bin/cat >> "$mock_bin/uname" <<'SCRIPT'
case "$1" in
    -s) echo "Linux" ;;
    -m) echo "x86_64" ;;
    *) /usr/bin/uname "$@" ;;
esac
SCRIPT
    chmod +x "$mock_bin/uname"

    echo '#!/bin/bash' > "$mock_bin/mktemp"
    echo "echo $TEST_TEMP_DIR/cliff-dl" >> "$mock_bin/mktemp"
    echo "mkdir -p $TEST_TEMP_DIR/cliff-dl" >> "$mock_bin/mktemp"
    chmod +x "$mock_bin/mktemp"

    local exit_code=0
    PATH="$mock_bin:/usr/bin:/bin" ensure_git_cliff 2>/dev/null || exit_code=$?

    assert_not_equals "0" "$exit_code" "Returns non-zero when download fails"
}

# ============================================================================
# Test: Function is defined after sourcing
# ============================================================================
test_ensure_git_cliff_function_defined() {
    setup_cliff_env
    source "$PROJECT_ROOT/bin/lib/release/git-cliff.sh"
    assert_function_exists "ensure_git_cliff" "ensure_git_cliff function is defined"
}

# Run tests
run_test test_ensure_git_cliff_already_installed "Returns 0 when git-cliff already installed"
run_test test_ensure_git_cliff_installs_via_cargo "Tries cargo install when cargo available"
run_test test_ensure_git_cliff_linux_x86_url "Correct URL mapping for linux x86_64"
run_test test_ensure_git_cliff_darwin_arm_url "Correct URL mapping for darwin arm64"
run_test test_ensure_git_cliff_unsupported_arch "Returns error for unsupported architecture"
run_test test_ensure_git_cliff_unsupported_os "Returns error for unsupported OS"
run_test test_ensure_git_cliff_download_failure "Returns error when download fails"
run_test test_ensure_git_cliff_function_defined "Function is defined after sourcing"

# Generate test report
generate_report
