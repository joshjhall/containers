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
    echo '#!/bin/bash' >"$mock_bin/git-cliff"
    echo 'echo "git-cliff 2.8.0"' >>"$mock_bin/git-cliff"
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
    echo '#!/bin/bash' >"$mock_bin/cargo"
    echo 'echo "CARGO_INSTALL_CALLED $@" > '"$TEST_TEMP_DIR/cargo_log"'' >>"$mock_bin/cargo"
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
    # shfmt may add spaces around | in case patterns (aarch64|arm64 vs aarch64 | arm64)
    if /usr/bin/grep -qE 'aarch64[[:space:]]*\|[[:space:]]*arm64\) arch="aarch64"' \
        "$PROJECT_ROOT/bin/lib/release/git-cliff.sh"; then
        assert_true true "Script maps arm64 to aarch64"
    else
        assert_true false "Script maps arm64 to aarch64"
    fi
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

    echo '#!/bin/bash' >"$mock_bin/curl"
    echo 'exit 1' >>"$mock_bin/curl"
    chmod +x "$mock_bin/curl"

    echo '#!/bin/bash' >"$mock_bin/uname"
    /usr/bin/cat >>"$mock_bin/uname" <<'SCRIPT'
case "$1" in
    -s) echo "Linux" ;;
    -m) echo "x86_64" ;;
    *) /usr/bin/uname "$@" ;;
esac
SCRIPT
    chmod +x "$mock_bin/uname"

    echo '#!/bin/bash' >"$mock_bin/mktemp"
    echo "echo $TEST_TEMP_DIR/cliff-dl" >>"$mock_bin/mktemp"
    echo "mkdir -p $TEST_TEMP_DIR/cliff-dl" >>"$mock_bin/mktemp"
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

# ============================================================================
# run_git_cliff_changelog: worktree-safe invocation + empty-output guard
# ============================================================================

# _stub_git_cliff <changelog-body> - put a git-cliff stub on a fresh bin dir
# (echoed) that logs its argv to $TEST_TEMP_DIR/cliff_args and writes
# <changelog-body> to its -o target.
_stub_git_cliff() {
    local mock_bin="$TEST_TEMP_DIR/cliffbin"
    command mkdir -p "$mock_bin"
    printf '%s' "$1" >"$TEST_TEMP_DIR/cliff_body"
    {
        echo '#!/bin/bash'
        echo "printf '%s\n' \"\$@\" >'$TEST_TEMP_DIR/cliff_args'"
        echo 'out=""; prev=""'
        echo 'for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done'
        echo "cat '$TEST_TEMP_DIR/cliff_body' >\"\$out\""
    } >"$mock_bin/git-cliff"
    command chmod +x "$mock_bin/git-cliff"
    echo "$mock_bin"
}

test_run_git_cliff_changelog_passes_workdir() {
    # Without --workdir, git-cliff 2.8.0 in a linked worktree matches no
    # commits and writes a header-only CHANGELOG (the 2026-10-25 re-release).
    setup_cliff_env
    source "$PROJECT_ROOT/bin/lib/release/git-cliff.sh"
    local root="$TEST_TEMP_DIR/root" mock_bin rc=0
    command mkdir -p "$root"
    mock_bin="$(_stub_git_cliff $'# Changelog\n\n## [9.9.9] - 2026-10-25\n')"
    PATH="$mock_bin:$PATH" run_git_cliff_changelog 9.9.9 "$root" >/dev/null 2>&1 || rc=$?
    assert_equals "0" "$rc" "returns 0 when releases were generated"
    assert_equals "--workdir" "$(command sed -n 1p "$TEST_TEMP_DIR/cliff_args")" \
        "first git-cliff arg is --workdir"
    assert_equals "$root" "$(command sed -n 2p "$TEST_TEMP_DIR/cliff_args")" \
        "--workdir is the project root"
    assert_file_contains "$root/CHANGELOG.md" "^## .9.9.9. - 2026-10-25" \
        "CHANGELOG.md holds the generated output"
}

test_run_git_cliff_changelog_refuses_empty_output() {
    setup_cliff_env
    source "$PROJECT_ROOT/bin/lib/release/git-cliff.sh"
    local root="$TEST_TEMP_DIR/root" mock_bin rc=0
    command mkdir -p "$root"
    printf '# Changelog\n\n## [1.0.0] - 2026-01-01\n' >"$root/CHANGELOG.md"
    mock_bin="$(_stub_git_cliff $'# Changelog\n\nheader only\n')"
    PATH="$mock_bin:$PATH" run_git_cliff_changelog 9.9.9 "$root" >/dev/null 2>&1 || rc=$?
    assert_equals "1" "$rc" "returns 1 when git-cliff emitted no release section"
    assert_file_contains "$root/CHANGELOG.md" "^## .1.0.0. - 2026-01-01" \
        "existing CHANGELOG.md is left intact"
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
run_test test_run_git_cliff_changelog_passes_workdir "run_git_cliff_changelog passes --workdir"
run_test test_run_git_cliff_changelog_refuses_empty_output "run_git_cliff_changelog keeps CHANGELOG.md on empty output"

# Generate test report
generate_report
