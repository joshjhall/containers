#!/usr/bin/env bash
# Unit tests for bin/lib/update-versions/helpers.sh

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Bin Lib Update Versions Helpers Tests"

# ============================================================================
# Test: Script sources without errors
# ============================================================================
test_script_sources_cleanly() {
    # Source dependencies first
    source "$PROJECT_ROOT/bin/lib/common.sh"
    source "$PROJECT_ROOT/bin/lib/version-utils.sh"

    # Source the script in a subshell to catch any errors
    if (source "$PROJECT_ROOT/bin/lib/update-versions/helpers.sh" 2>&1 | grep -qi "error\|fail"); then
        assert_true false "helpers.sh has sourcing errors"
    else
        assert_true true "helpers.sh sources without errors"
    fi
}

# ============================================================================
# Test: extract_checksum_from_file function
# ============================================================================
test_extract_checksum_from_file() {
    source "$PROJECT_ROOT/bin/lib/common.sh"
    source "$PROJECT_ROOT/bin/lib/version-utils.sh"
    source "$PROJECT_ROOT/bin/lib/update-versions/helpers.sh"

    # Create mock checksum file content
    local checksums="bda09dc030a08987fe2b3bed678b15b52f23d6705e872d561932d4ca07db7818  k9s_Linux_amd64.tar.gz
7f3b414bc5e6b584fbcb97f9f4f5b2c67a51cdffcbccb95adcadbaeab904e98e  k9s_Linux_arm64.tar.gz"

    # Extract checksum for amd64
    local checksum
    checksum=$(echo "$checksums" | extract_checksum_from_file "k9s_Linux_amd64.tar.gz")

    assert_equals "bda09dc030a08987fe2b3bed678b15b52f23d6705e872d561932d4ca07db7818" "$checksum" "Extracted correct amd64 checksum"

    # Extract checksum for arm64
    checksum=$(echo "$checksums" | extract_checksum_from_file "k9s_Linux_arm64.tar.gz")

    assert_equals "7f3b414bc5e6b584fbcb97f9f4f5b2c67a51cdffcbccb95adcadbaeab904e98e" "$checksum" "Extracted correct arm64 checksum"
}

# ============================================================================
# Test: update_checksum_variable function
# ============================================================================
test_update_checksum_variable() {
    source "$PROJECT_ROOT/bin/lib/common.sh"
    source "$PROJECT_ROOT/bin/lib/version-utils.sh"
    source "$PROJECT_ROOT/bin/lib/update-versions/helpers.sh"

    # Create temporary test file
    local test_file="$RESULTS_DIR/test_checksum_update.sh"
    command cat > "$test_file" <<'EOF'
#!/bin/bash
K9S_AMD64_SHA256="old_checksum_abc123"
K9S_ARM64_SHA256="old_checksum_def456"
EOF

    # Update checksum
    local new_checksum="bda09dc030a08987fe2b3bed678b15b52f23d6705e872d561932d4ca07db7818"

    if update_checksum_variable "$test_file" "K9S_AMD64_SHA256" "$new_checksum" 2>/dev/null; then
        # Verify the update
        if grep -q "K9S_AMD64_SHA256=\"$new_checksum\"" "$test_file"; then
            assert_true true "update_checksum_variable successfully updated checksum"
        else
            assert_true false "Checksum was not updated in file"
        fi
    else
        assert_true false "update_checksum_variable failed"
    fi

    # Clean up
    command rm -f "$test_file"
}

# ============================================================================
# Test: verify_checksum_update function
# ============================================================================
test_verify_checksum_update() {
    source "$PROJECT_ROOT/bin/lib/common.sh"
    source "$PROJECT_ROOT/bin/lib/version-utils.sh"
    source "$PROJECT_ROOT/bin/lib/update-versions/helpers.sh"

    # Create temporary test file
    local test_file="$RESULTS_DIR/test_verify_checksum.sh"
    command cat > "$test_file" <<'EOF'
#!/bin/bash
K9S_AMD64_SHA256="bda09dc030a08987fe2b3bed678b15b52f23d6705e872d561932d4ca07db7818"
EOF

    # Verify matching checksum
    if verify_checksum_update "$test_file" "K9S_AMD64_SHA256" "bda09dc030a08987fe2b3bed678b15b52f23d6705e872d561932d4ca07db7818" 2>/dev/null; then
        assert_true true "verify_checksum_update succeeds for matching checksum"
    else
        assert_true false "verify_checksum_update failed for matching checksum"
    fi

    # Verify mismatching checksum
    if verify_checksum_update "$test_file" "K9S_AMD64_SHA256" "wrongchecksum00000000000000000000000000000000000000000000000000" 2>/dev/null; then
        assert_true false "verify_checksum_update should fail for mismatched checksum"
    else
        assert_true true "verify_checksum_update correctly fails for mismatched checksum"
    fi

    # Clean up
    command rm -f "$test_file"
}

# ============================================================================
# Test: update_version_comment function
# ============================================================================
test_update_version_comment() {
    source "$PROJECT_ROOT/bin/lib/common.sh"
    source "$PROJECT_ROOT/bin/lib/version-utils.sh"
    source "$PROJECT_ROOT/bin/lib/update-versions/helpers.sh"

    # Create temporary test file
    local test_file="$RESULTS_DIR/test_version_comment.sh"
    command cat > "$test_file" <<'EOF'
#!/bin/bash
# Verified on: 2025-01-01
K9S_VERSION="0.50.16"
EOF

    # Update comment
    if update_version_comment "$test_file" "# Verified on:" "2025-11-07" 2>/dev/null; then
        # Verify the update
        if grep -q "# Verified on: 2025-11-07" "$test_file"; then
            assert_true true "update_version_comment successfully updated comment"
        else
            assert_true false "Comment was not updated in file"
        fi
    else
        assert_true false "update_version_comment failed"
    fi

    # Clean up
    command rm -f "$test_file"
}

# ============================================================================
# Test: Required commands check
# ============================================================================
test_required_commands_available() {
    # These commands must be available for helpers.sh to work
    assert_command_exists curl "curl is available"
    assert_command_exists sed "sed is available"
    assert_command_exists awk "awk is available"
    assert_command_exists grep "grep is available"
}

# ============================================================================
# Test: Script has proper functions defined
# ============================================================================
test_helper_functions_defined() {
    source "$PROJECT_ROOT/bin/lib/common.sh"
    source "$PROJECT_ROOT/bin/lib/version-utils.sh"
    source "$PROJECT_ROOT/bin/lib/update-versions/helpers.sh"

    # Check that key functions are defined
    if declare -f fetch_github_checksum_file >/dev/null; then
        assert_true true "fetch_github_checksum_file is defined"
    else
        assert_true false "fetch_github_checksum_file is not defined"
    fi

    if declare -f extract_checksum_from_file >/dev/null; then
        assert_true true "extract_checksum_from_file is defined"
    else
        assert_true false "extract_checksum_from_file is not defined"
    fi

    if declare -f update_checksum_variable >/dev/null; then
        assert_true true "update_checksum_variable is defined"
    else
        assert_true false "update_checksum_variable is not defined"
    fi

    if declare -f verify_checksum_update >/dev/null; then
        assert_true true "verify_checksum_update is defined"
    else
        assert_true false "verify_checksum_update is not defined"
    fi
}

# Run tests
run_test test_script_sources_cleanly "Script sources without errors"
run_test test_extract_checksum_from_file "extract_checksum_from_file works correctly"
run_test test_update_checksum_variable "update_checksum_variable updates checksums"
run_test test_verify_checksum_update "verify_checksum_update validates correctly"
run_test test_update_version_comment "update_version_comment updates comments"
run_test test_required_commands_available "Required commands are available"
run_test test_helper_functions_defined "Helper functions are defined"

# Generate test report
generate_report
