#!/usr/bin/env bash
# Unit tests for bin/lib/common.sh

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Bin Lib Common Tests"

# ============================================================================
# Test: Color codes are defined
# ============================================================================
test_color_codes_defined() {
    source "$PROJECT_ROOT/bin/lib/common.sh"

    assert_not_empty "$RED" "RED color code defined"
    assert_not_empty "$GREEN" "GREEN color code defined"
    assert_not_empty "$YELLOW" "YELLOW color code defined"
    assert_not_empty "$BLUE" "BLUE color code defined"
    assert_not_empty "$NC" "NC (no color) code defined"
}

# ============================================================================
# Test: Logging functions work
# ============================================================================
test_log_info() {
    source "$PROJECT_ROOT/bin/lib/common.sh"

    local output
    output=$(log_info "Test message" 2>&1)

    if echo "$output" | grep -q "Test message"; then
        assert_true true "log_info outputs message"
    else
        assert_true false "log_info failed to output message"
    fi
}

test_log_success() {
    source "$PROJECT_ROOT/bin/lib/common.sh"

    local output
    output=$(log_success "Success message" 2>&1)

    if echo "$output" | grep -q "Success message"; then
        assert_true true "log_success outputs message"
    else
        assert_true false "log_success failed to output message"
    fi
}

test_log_warning() {
    source "$PROJECT_ROOT/bin/lib/common.sh"

    local output
    output=$(log_warning "Warning message" 2>&1)

    if echo "$output" | grep -q "Warning message"; then
        assert_true true "log_warning outputs message"
    else
        assert_true false "log_warning failed to output message"
    fi
}

test_log_error() {
    source "$PROJECT_ROOT/bin/lib/common.sh"

    local output
    output=$(log_error "Error message" 2>&1)

    if echo "$output" | grep -q "Error message"; then
        assert_true true "log_error outputs message to stderr"
    else
        assert_true false "log_error failed to output message"
    fi
}

# ============================================================================
# Test: Path resolution functions
# ============================================================================
test_get_script_dir() {
    source "$PROJECT_ROOT/bin/lib/common.sh"

    local script_dir
    script_dir=$(get_script_dir)

    # Should return a valid directory
    if [ -d "$script_dir" ]; then
        assert_true true "get_script_dir returns a valid directory"
    else
        assert_true false "get_script_dir returned invalid path: $script_dir"
    fi
}

test_get_project_root() {
    source "$PROJECT_ROOT/bin/lib/common.sh"

    local project_root
    project_root=$(get_project_root)

    # Should return a valid directory
    if [ -d "$project_root" ]; then
        assert_true true "get_project_root returns a valid directory"
    else
        assert_true false "get_project_root returned invalid path: $project_root"
    fi

    # Should have a bin directory
    if [ -d "$project_root/bin" ]; then
        assert_true true "get_project_root returns path with bin/ directory"
    else
        assert_true false "get_project_root path missing bin/ directory"
    fi
}

# ============================================================================
# Test: Utility functions
# ============================================================================
test_require_command_exists() {
    source "$PROJECT_ROOT/bin/lib/common.sh"

    # Test with a command that should exist
    if require_command bash 2>/dev/null; then
        assert_true true "require_command succeeds for existing command"
    else
        assert_true false "require_command failed for bash"
    fi
}

test_require_command_missing() {
    source "$PROJECT_ROOT/bin/lib/common.sh"

    # Test with a command that should not exist
    # Run in subshell since require_command calls exit, not return
    (require_command nonexistent_command_xyz 2>/dev/null)
    local exit_code=$?

    if [ $exit_code -eq 1 ]; then
        assert_true true "require_command correctly exits with 1 for missing command"
    else
        assert_true false "require_command did not exit with 1 for missing command (got: $exit_code)"
    fi
}

test_get_current_date() {
    source "$PROJECT_ROOT/bin/lib/common.sh"

    local current_date
    current_date=$(get_current_date)

    # Check format YYYY-MM-DD
    if [[ "$current_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        assert_true true "get_current_date returns YYYY-MM-DD format"
    else
        assert_true false "get_current_date returned invalid format: $current_date"
    fi
}

# ============================================================================
# Test: Color codes format
# ============================================================================
test_color_codes_format() {
    source "$PROJECT_ROOT/bin/lib/common.sh"

    # ANSI color codes should start with \033[
    if [[ "$RED" == *"033["* ]]; then
        assert_true true "RED has ANSI escape sequence"
    else
        assert_true false "RED missing ANSI escape sequence"
    fi

    if [[ "$NC" == *"033["* ]] || [[ "$NC" == *"0m"* ]]; then
        assert_true true "NC (no color) has reset sequence"
    else
        assert_true false "NC missing reset sequence"
    fi
}

# ============================================================================
# Test: Script sources without errors
# ============================================================================
test_script_sources_cleanly() {
    # Source the script in a subshell to catch any errors
    if (source "$PROJECT_ROOT/bin/lib/common.sh" 2>&1 | grep -qi "error"); then
        assert_true false "common.sh has sourcing errors"
    else
        assert_true true "common.sh sources without errors"
    fi
}

# Run tests
run_test test_color_codes_defined "Color codes are defined"
run_test test_log_info "log_info function works"
run_test test_log_success "log_success function works"
run_test test_log_warning "log_warning function works"
run_test test_log_error "log_error function works"
run_test test_get_script_dir "get_script_dir returns valid directory"
run_test test_get_project_root "get_project_root returns valid directory"
run_test test_require_command_exists "require_command works for existing commands"
run_test test_require_command_missing "require_command fails for missing commands"
run_test test_get_current_date "get_current_date returns YYYY-MM-DD format"
run_test test_color_codes_format "Color codes have proper ANSI format"
run_test test_script_sources_cleanly "Script sources without errors"

# Generate test report
generate_report
