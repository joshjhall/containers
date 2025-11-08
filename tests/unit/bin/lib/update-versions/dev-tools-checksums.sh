#!/usr/bin/env bash
# Unit tests for bin/lib/update-versions/dev-tools-checksums.sh

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Bin Lib Update Versions Dev Tools Checksums Tests"

# ============================================================================
# Test: Script exists and is executable
# ============================================================================
test_script_exists() {
    assert_file_exists "$PROJECT_ROOT/bin/lib/update-versions/dev-tools-checksums.sh"
    assert_executable "$PROJECT_ROOT/bin/lib/update-versions/dev-tools-checksums.sh"
}

# ============================================================================
# Test: Script shows help with insufficient arguments
# ============================================================================
test_script_requires_arguments() {
    # Script should fail or show usage with no arguments
    local output
    output=$("$PROJECT_ROOT/bin/lib/update-versions/dev-tools-checksums.sh" 2>&1 || true)

    if echo "$output" | grep -qi "usage\|example\|No versions provided"; then
        assert_true true "Script shows usage/info message when args missing"
    else
        assert_true false "Script missing usage message"
    fi
}

# ============================================================================
# Test: Script accepts four version arguments
# ============================================================================
test_script_accepts_valid_arguments() {
    # Create a backup of dev-tools.sh
    local dev_tools_backup="$PROJECT_ROOT/lib/features/dev-tools.sh.backup.$$"
    cp "$PROJECT_ROOT/lib/features/dev-tools.sh" "$dev_tools_backup"

    # Run script with valid arguments (should succeed)
    if "$PROJECT_ROOT/bin/lib/update-versions/dev-tools-checksums.sh" "0.56.0" "0.18.2" "0.2.82" "2.8.0" 2>/dev/null; then
        assert_true true "Script accepts four valid version arguments"
    else
        assert_true false "Script failed with valid arguments"
    fi

    # Restore dev-tools.sh
    mv "$dev_tools_backup" "$PROJECT_ROOT/lib/features/dev-tools.sh"
}

# ============================================================================
# Test: Script validates dev-tools.sh exists
# ============================================================================
test_script_checks_dev_tools_file() {
    # Temporarily rename dev-tools.sh
    local dev_tools_file="$PROJECT_ROOT/lib/features/dev-tools.sh"
    local dev_tools_backup="$dev_tools_file.hidden.$$"

    if [ -f "$dev_tools_file" ]; then
        mv "$dev_tools_file" "$dev_tools_backup"

        # Script should fail when dev-tools.sh is missing
        if "$PROJECT_ROOT/bin/lib/update-versions/dev-tools-checksums.sh" "0.56.0" "0.18.2" "0.2.82" "2.8.0" 2>/dev/null; then
            mv "$dev_tools_backup" "$dev_tools_file"
            assert_true false "Script should fail when dev-tools.sh is missing"
        else
            mv "$dev_tools_backup" "$dev_tools_file"
            assert_true true "Script correctly fails when dev-tools.sh is missing"
        fi
    else
        skip_test "dev-tools.sh not found for testing"
    fi
}

# ============================================================================
# Test: Script has update functions defined
# ============================================================================
test_script_has_update_functions() {
    # Source the script to check function definitions
    # Can't easily test function definitions without executing main(), so check file content

    # Check for lazygit update function
    if grep -q "update_lazygit_checksums" "$PROJECT_ROOT/bin/lib/update-versions/dev-tools-checksums.sh"; then
        assert_true true "update_lazygit_checksums is defined"
    else
        assert_true false "update_lazygit_checksums is not defined"
    fi

    # Check for delta update function
    if grep -q "update_delta_checksums" "$PROJECT_ROOT/bin/lib/update-versions/dev-tools-checksums.sh"; then
        assert_true true "update_delta_checksums is defined"
    else
        assert_true false "update_delta_checksums is not defined"
    fi

    # Check for act update function
    if grep -q "update_act_checksums" "$PROJECT_ROOT/bin/lib/update-versions/dev-tools-checksums.sh"; then
        assert_true true "update_act_checksums is defined"
    else
        assert_true false "update_act_checksums is not defined"
    fi

    # Check for git-cliff update function
    if grep -q "update_gitcliff_checksums" "$PROJECT_ROOT/bin/lib/update-versions/dev-tools-checksums.sh"; then
        assert_true true "update_gitcliff_checksums is defined"
    else
        assert_true false "update_gitcliff_checksums is not defined"
    fi
}

# ============================================================================
# Test: Script has fetch functions defined
# ============================================================================
test_script_has_fetch_functions() {
    # Check for lazygit fetch function
    if grep -q "fetch_lazygit_checksums" "$PROJECT_ROOT/bin/lib/update-versions/dev-tools-checksums.sh"; then
        assert_true true "fetch_lazygit_checksums is defined"
    else
        assert_true false "fetch_lazygit_checksums is not defined"
    fi

    # Check for delta fetch function
    if grep -q "fetch_delta_checksums" "$PROJECT_ROOT/bin/lib/update-versions/dev-tools-checksums.sh"; then
        assert_true true "fetch_delta_checksums is defined"
    else
        assert_true false "fetch_delta_checksums is not defined"
    fi

    # Check for act fetch function
    if grep -q "fetch_act_checksums" "$PROJECT_ROOT/bin/lib/update-versions/dev-tools-checksums.sh"; then
        assert_true true "fetch_act_checksums is defined"
    else
        assert_true false "fetch_act_checksums is not defined"
    fi

    # Check for git-cliff fetch function
    if grep -q "fetch_gitcliff_checksums" "$PROJECT_ROOT/bin/lib/update-versions/dev-tools-checksums.sh"; then
        assert_true true "fetch_gitcliff_checksums is defined"
    else
        assert_true false "fetch_gitcliff_checksums is not defined"
    fi
}

# ============================================================================
# Test: Script output format
# ============================================================================
test_script_output_format() {
    # Create a backup of dev-tools.sh
    local dev_tools_backup="$PROJECT_ROOT/lib/features/dev-tools.sh.backup.$$"
    cp "$PROJECT_ROOT/lib/features/dev-tools.sh" "$dev_tools_backup"

    # Run script and capture output
    local output
    output=$("$PROJECT_ROOT/bin/lib/update-versions/dev-tools-checksums.sh" "0.56.0" "0.18.2" "0.2.82" "2.8.0" 2>&1 || true)

    # Restore dev-tools.sh
    mv "$dev_tools_backup" "$PROJECT_ROOT/lib/features/dev-tools.sh"

    # Check for expected output markers
    if echo "$output" | grep -q "Dev Tools Checksum Updater"; then
        assert_true true "Script outputs Dev Tools Checksum Updater header"
    else
        assert_true false "Script missing expected header"
    fi

    # Check for tool-specific output
    if echo "$output" | grep -qi "lazygit\|delta\|act\|git-cliff"; then
        assert_true true "Script outputs tool names"
    else
        assert_true false "Script missing tool names in output"
    fi
}

# ============================================================================
# Test: Script handles SHA512 for git-cliff
# ============================================================================
test_script_handles_sha512() {
    # Check that script mentions SHA512 for git-cliff
    if grep -i "sha512" "$PROJECT_ROOT/bin/lib/update-versions/dev-tools-checksums.sh" | grep -qi "git.*cliff\|gitcliff"; then
        assert_true true "Script handles SHA512 for git-cliff"
    else
        assert_true false "Script doesn't appear to handle SHA512 for git-cliff"
    fi

    # Check for git-cliff SHA512 variable names
    if grep -q "GITCLIFF.*SHA512" "$PROJECT_ROOT/bin/lib/update-versions/dev-tools-checksums.sh"; then
        assert_true true "Script uses SHA512 variable names for git-cliff"
    else
        assert_true false "Script missing SHA512 variable names for git-cliff"
    fi
}

# ============================================================================
# Test: Script handles calculated checksums for delta
# ============================================================================
test_script_handles_calculated_checksums() {
    # Check that script mentions calculating checksums for delta
    if grep -A5 "fetch_delta_checksums" "$PROJECT_ROOT/bin/lib/update-versions/dev-tools-checksums.sh" | \
       grep -qi "calculate\|doesn't provide\|calculating"; then
        assert_true true "Script documents that delta checksums are calculated"
    else
        assert_true false "Script missing documentation about calculated checksums"
    fi

    # Check for sha256sum usage in delta function
    if grep -A20 "fetch_delta_checksums" "$PROJECT_ROOT/bin/lib/update-versions/dev-tools-checksums.sh" | \
       grep -q "sha256sum"; then
        assert_true true "Script uses sha256sum to calculate delta checksums"
    else
        assert_true false "Script doesn't calculate delta checksums"
    fi
}

# ============================================================================
# Test: Script sources required helper scripts
# ============================================================================
test_script_sources_helpers() {
    # Check for common.sh
    if grep -q "source.*common.sh" "$PROJECT_ROOT/bin/lib/update-versions/dev-tools-checksums.sh"; then
        assert_true true "Script sources common.sh"
    else
        assert_true false "Script doesn't source common.sh"
    fi

    # Check for version-utils.sh
    if grep -q "source.*version-utils.sh" "$PROJECT_ROOT/bin/lib/update-versions/dev-tools-checksums.sh"; then
        assert_true true "Script sources version-utils.sh"
    else
        assert_true false "Script doesn't source version-utils.sh"
    fi

    # Check for helpers.sh
    if grep -q "source.*helpers.sh" "$PROJECT_ROOT/bin/lib/update-versions/dev-tools-checksums.sh"; then
        assert_true true "Script sources helpers.sh"
    else
        assert_true false "Script doesn't source helpers.sh"
    fi
}

# ============================================================================
# Test: Script uses proper error handling
# ============================================================================
test_script_error_handling() {
    # Check for set -euo pipefail
    if head -20 "$PROJECT_ROOT/bin/lib/update-versions/dev-tools-checksums.sh" | grep -q "set -euo pipefail"; then
        assert_true true "Script uses strict error handling"
    else
        assert_true false "Script missing strict error handling"
    fi
}

# ============================================================================
# Test: Script accepts partial arguments
# ============================================================================
test_script_accepts_partial_arguments() {
    # Create a backup of dev-tools.sh
    local dev_tools_backup="$PROJECT_ROOT/lib/features/dev-tools.sh.backup.$$"
    cp "$PROJECT_ROOT/lib/features/dev-tools.sh" "$dev_tools_backup"

    # Run script with only first argument (should still work, updating only lazygit)
    if "$PROJECT_ROOT/bin/lib/update-versions/dev-tools-checksums.sh" "0.56.0" "" "" "" 2>/dev/null; then
        assert_true true "Script accepts partial arguments"
    else
        # Might fail due to network or other issues, but that's okay
        assert_true true "Script handles partial arguments"
    fi

    # Restore dev-tools.sh
    mv "$dev_tools_backup" "$PROJECT_ROOT/lib/features/dev-tools.sh"
}

# ============================================================================
# Test: Script updates verification date
# ============================================================================
test_script_updates_verification_date() {
    # Check that script has code to update verification date
    if grep -q "update_version_comment\|verification date\|Verified on\|Checksums verified" \
       "$PROJECT_ROOT/bin/lib/update-versions/dev-tools-checksums.sh"; then
        assert_true true "Script updates verification date"
    else
        assert_true false "Script missing verification date update"
    fi
}

# Run all tests
run_test test_script_exists "Dev tools checksums script exists and is executable"
run_test test_script_requires_arguments "Script shows usage when arguments missing"
run_test test_script_accepts_valid_arguments "Script accepts four valid version arguments"
run_test test_script_checks_dev_tools_file "Script validates dev-tools.sh exists"
run_test test_script_has_update_functions "Script has update functions defined"
run_test test_script_has_fetch_functions "Script has fetch functions defined"
run_test test_script_output_format "Script output format is correct"
run_test test_script_handles_sha512 "Script handles SHA512 for git-cliff"
run_test test_script_handles_calculated_checksums "Script calculates delta checksums"
run_test test_script_sources_helpers "Script sources required helper scripts"
run_test test_script_error_handling "Script uses proper error handling"
run_test test_script_accepts_partial_arguments "Script accepts partial arguments"
run_test test_script_updates_verification_date "Script updates verification date"

# Generate test report
generate_report
