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
    if (source "$PROJECT_ROOT/bin/lib/update-versions/helpers.sh" 2>&1 | command grep -qi "error\|fail"); then
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
    command cat >"$test_file" <<'EOF'
#!/bin/bash
K9S_AMD64_SHA256="old_checksum_abc123"
K9S_ARM64_SHA256="old_checksum_def456"
EOF

    # Update checksum
    local new_checksum="bda09dc030a08987fe2b3bed678b15b52f23d6705e872d561932d4ca07db7818"

    if update_checksum_variable "$test_file" "K9S_AMD64_SHA256" "$new_checksum" 2>/dev/null; then
        # Verify the update
        if command grep -q "K9S_AMD64_SHA256=\"$new_checksum\"" "$test_file"; then
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
    command cat >"$test_file" <<'EOF'
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
    command cat >"$test_file" <<'EOF'
#!/bin/bash
# Verified on: 2025-01-01
K9S_VERSION="0.50.16"
EOF

    # Update comment
    if update_version_comment "$test_file" "# Verified on:" "2025-11-07" 2>/dev/null; then
        # Verify the update
        if command grep -q "# Verified on: 2025-11-07" "$test_file"; then
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

# ============================================================================
# Test: update_checksum_variable rejects invalid checksums
# ============================================================================

test_update_checksum_rejects_short_hash() {
    source "$PROJECT_ROOT/bin/lib/common.sh"
    source "$PROJECT_ROOT/bin/lib/version-utils.sh"
    source "$PROJECT_ROOT/bin/lib/update-versions/helpers.sh"

    local test_file="$RESULTS_DIR/test_reject_short.sh"
    command cat >"$test_file" <<'EOF'
#!/bin/bash
MY_SHA256="old_value"
EOF

    # 32-char hex string (MD5 length) — should be rejected
    local short_hash="abcdef0123456789abcdef0123456789"
    local exit_code=0
    update_checksum_variable "$test_file" "MY_SHA256" "$short_hash" 2>/dev/null || exit_code=$?

    assert_equals "1" "$exit_code" \
        "update_checksum_variable should reject 32-char (MD5-length) hash"
    command rm -f "$test_file"
}

test_update_checksum_rejects_non_hex() {
    source "$PROJECT_ROOT/bin/lib/common.sh"
    source "$PROJECT_ROOT/bin/lib/version-utils.sh"
    source "$PROJECT_ROOT/bin/lib/update-versions/helpers.sh"

    local test_file="$RESULTS_DIR/test_reject_nonhex.sh"
    command cat >"$test_file" <<'EOF'
#!/bin/bash
MY_SHA256="old_value"
EOF

    # 64-char string but with non-hex characters
    local non_hex="zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"
    local exit_code=0
    update_checksum_variable "$test_file" "MY_SHA256" "$non_hex" 2>/dev/null || exit_code=$?

    assert_equals "1" "$exit_code" \
        "update_checksum_variable should reject non-hex 64-char string"
    command rm -f "$test_file"
}

test_update_checksum_rejects_empty() {
    source "$PROJECT_ROOT/bin/lib/common.sh"
    source "$PROJECT_ROOT/bin/lib/version-utils.sh"
    source "$PROJECT_ROOT/bin/lib/update-versions/helpers.sh"

    local test_file="$RESULTS_DIR/test_reject_empty.sh"
    command cat >"$test_file" <<'EOF'
#!/bin/bash
MY_SHA256="old_value"
EOF

    local exit_code=0
    update_checksum_variable "$test_file" "MY_SHA256" "" 2>/dev/null || exit_code=$?

    assert_equals "1" "$exit_code" \
        "update_checksum_variable should reject empty checksum"
    command rm -f "$test_file"
}

test_update_checksum_accepts_sha512() {
    source "$PROJECT_ROOT/bin/lib/common.sh"
    source "$PROJECT_ROOT/bin/lib/version-utils.sh"
    source "$PROJECT_ROOT/bin/lib/update-versions/helpers.sh"

    local test_file="$RESULTS_DIR/test_accept_sha512.sh"
    command cat >"$test_file" <<'EOF'
#!/bin/bash
MY_SHA512="old_value"
EOF

    # Valid 128-char hex string (SHA-512)
    local sha512="cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e"
    local exit_code=0
    update_checksum_variable "$test_file" "MY_SHA512" "$sha512" 2>/dev/null || exit_code=$?

    assert_equals "0" "$exit_code" \
        "update_checksum_variable should accept valid SHA-512 (128-char hex)"

    # Verify the file was actually updated
    if command grep -q "MY_SHA512=\"$sha512\"" "$test_file"; then
        pass_test "SHA-512 checksum was written to file"
    else
        fail_test "SHA-512 checksum was not written to file"
    fi
    command rm -f "$test_file"
}

# Run tests
run_test test_script_sources_cleanly "Script sources without errors"
run_test test_extract_checksum_from_file "extract_checksum_from_file works correctly"
run_test test_update_checksum_variable "update_checksum_variable updates checksums"
run_test test_verify_checksum_update "verify_checksum_update validates correctly"
run_test test_update_version_comment "update_version_comment updates comments"
run_test test_required_commands_available "Required commands are available"
run_test test_helper_functions_defined "Helper functions are defined"

# Invalid checksum rejection
run_test test_update_checksum_rejects_short_hash "update_checksum_variable rejects short (MD5-length) hash"
run_test test_update_checksum_rejects_non_hex "update_checksum_variable rejects non-hex characters"
run_test test_update_checksum_rejects_empty "update_checksum_variable rejects empty checksum"
run_test test_update_checksum_accepts_sha512 "update_checksum_variable accepts valid SHA-512"

# Generate test report
generate_report
