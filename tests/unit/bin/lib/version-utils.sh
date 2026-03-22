#!/usr/bin/env bash
# Unit tests for bin/lib/version-utils.sh

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Bin Lib Version Utils Tests"

# ============================================================================
# Test: validate_version function
# ============================================================================
test_validate_version_valid() {
    source "$PROJECT_ROOT/bin/lib/version-utils.sh"

    # Test valid version formats
    if validate_version "1.2.3"; then
        assert_true true "validate_version accepts 1.2.3"
    else
        assert_true false "validate_version rejected valid version 1.2.3"
    fi

    if validate_version "22.18.0"; then
        assert_true true "validate_version accepts 22.18.0"
    else
        assert_true false "validate_version rejected valid version 22.18.0"
    fi

    if validate_version "3.13"; then
        assert_true true "validate_version accepts 3.13"
    else
        assert_true false "validate_version rejected valid version 3.13"
    fi
}

test_validate_version_invalid() {
    source "$PROJECT_ROOT/bin/lib/version-utils.sh"

    # Test invalid version formats
    if validate_version ""; then
        assert_true false "validate_version should reject empty string"
    else
        assert_true true "validate_version correctly rejects empty string"
    fi

    if validate_version "null"; then
        assert_true false "validate_version should reject 'null'"
    else
        assert_true true "validate_version correctly rejects 'null'"
    fi

    if validate_version "undefined"; then
        assert_true false "validate_version should reject 'undefined'"
    else
        assert_true true "validate_version correctly rejects 'undefined'"
    fi

    if validate_version "error"; then
        assert_true false "validate_version should reject 'error'"
    else
        assert_true true "validate_version correctly rejects 'error'"
    fi

    if validate_version "abc"; then
        assert_true false "validate_version should reject non-numeric 'abc'"
    else
        assert_true true "validate_version correctly rejects 'abc'"
    fi
}

test_validate_version_edge_cases() {
    source "$PROJECT_ROOT/bin/lib/version-utils.sh"

    # Date format
    if validate_version "2025-11-07"; then
        assert_true true "validate_version accepts date format 2025-11-07"
    else
        assert_true false "validate_version rejected date format"
    fi

    # Version with suffix
    if validate_version "1.2.3-beta"; then
        assert_true true "validate_version accepts version with suffix"
    else
        assert_true false "validate_version rejected version with suffix"
    fi

    # Java-style version
    if validate_version "11.0.1"; then
        assert_true true "validate_version accepts Java-style version"
    else
        assert_true false "validate_version rejected Java-style version"
    fi
}

# ============================================================================
# Test: validate_sha256 function
# ============================================================================
test_validate_sha256_valid() {
    source "$PROJECT_ROOT/bin/lib/version-utils.sh"

    # Valid SHA256 (64 hex characters)
    local valid_sha="bda09dc030a08987fe2b3bed678b15b52f23d6705e872d561932d4ca07db7818"

    if validate_sha256 "$valid_sha"; then
        assert_true true "validate_sha256 accepts valid 64-character hex"
    else
        assert_true false "validate_sha256 rejected valid SHA256"
    fi
}

test_validate_sha256_invalid() {
    source "$PROJECT_ROOT/bin/lib/version-utils.sh"

    # Too short
    if validate_sha256 "abc123"; then
        assert_true false "validate_sha256 should reject short string"
    else
        assert_true true "validate_sha256 correctly rejects short string"
    fi

    # Too long
    local too_long="bda09dc030a08987fe2b3bed678b15b52f23d6705e872d561932d4ca07db7818extra"
    if validate_sha256 "$too_long"; then
        assert_true false "validate_sha256 should reject 65+ character string"
    else
        assert_true true "validate_sha256 correctly rejects too-long string"
    fi

    # Non-hex characters
    local non_hex="zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"
    if validate_sha256 "$non_hex"; then
        assert_true false "validate_sha256 should reject non-hex characters"
    else
        assert_true true "validate_sha256 correctly rejects non-hex"
    fi

    # Empty
    if validate_sha256 ""; then
        assert_true false "validate_sha256 should reject empty string"
    else
        assert_true true "validate_sha256 correctly rejects empty string"
    fi
}

# ============================================================================
# Test: version_matches function
# ============================================================================
test_version_matches_exact() {
    source "$PROJECT_ROOT/bin/lib/version-utils.sh"

    # Exact match
    if version_matches "1.2.3" "1.2.3"; then
        assert_true true "version_matches accepts exact match 1.2.3"
    else
        assert_true false "version_matches rejected exact match"
    fi

    if version_matches "22.18.0" "22.18.0"; then
        assert_true true "version_matches accepts exact match 22.18.0"
    else
        assert_true false "version_matches rejected exact match"
    fi
}

test_version_matches_partial() {
    source "$PROJECT_ROOT/bin/lib/version-utils.sh"

    # Partial match: major.minor matches major.minor.patch
    if version_matches "1.33" "1.33.3"; then
        assert_true true "version_matches accepts partial match 1.33 → 1.33.3"
    else
        assert_true false "version_matches rejected partial match"
    fi

    # Partial match: major matches major.minor.patch
    if version_matches "22" "22.18.0"; then
        assert_true true "version_matches accepts partial match 22 → 22.18.0"
    else
        assert_true false "version_matches rejected partial match"
    fi

    # Partial match: major.minor.patch matches major.minor.patch.build
    if version_matches "3.13.6" "3.13.6.1"; then
        assert_true true "version_matches accepts 3.13.6 → 3.13.6.1"
    else
        assert_true false "version_matches rejected extended version"
    fi
}

test_version_matches_different() {
    source "$PROJECT_ROOT/bin/lib/version-utils.sh"

    # Different versions should not match
    if version_matches "1.32" "1.33.3"; then
        assert_true false "version_matches should reject different versions"
    else
        assert_true true "version_matches correctly rejects 1.32 vs 1.33.3"
    fi

    # Ensure partial check doesn't match incorrectly
    if version_matches "21" "210.0.0"; then
        assert_true false "version_matches should reject 21 vs 210.0.0"
    else
        assert_true true "version_matches correctly rejects 21 vs 210.0.0"
    fi

    if version_matches "3.12" "3.13.6"; then
        assert_true false "version_matches should reject 3.12 vs 3.13.6"
    else
        assert_true true "version_matches correctly rejects 3.12 vs 3.13.6"
    fi

    # Single-digit boundary: '2' must not match '20.0.0'
    if version_matches "2" "20.0.0"; then
        assert_true false "version_matches should reject 2 vs 20.0.0"
    else
        assert_true true "version_matches correctly rejects 2 vs 20.0.0"
    fi
}

# ============================================================================
# Test: Script sources without errors
# ============================================================================
test_script_sources_cleanly() {
    # Need to source common.sh first (dependency)
    source "$PROJECT_ROOT/bin/lib/common.sh"

    # Source the script in a subshell to catch any errors
    if (source "$PROJECT_ROOT/bin/lib/version-utils.sh" 2>&1 | command grep -qi "error"); then
        assert_true false "version-utils.sh has sourcing errors"
    else
        assert_true true "version-utils.sh sources without errors"
    fi
}

# ============================================================================
# Test: bump_version function
# ============================================================================
test_bump_version_patch() {
    source "$PROJECT_ROOT/bin/lib/version-utils.sh"

    local result
    result=$(bump_version "1.2.3" "patch")
    assert_equals "1.2.4" "$result" "bump_version patch increments patch"
}

test_bump_version_minor() {
    source "$PROJECT_ROOT/bin/lib/version-utils.sh"

    local result
    result=$(bump_version "1.2.3" "minor")
    assert_equals "1.3.0" "$result" "bump_version minor increments minor and resets patch"
}

test_bump_version_major() {
    source "$PROJECT_ROOT/bin/lib/version-utils.sh"

    local result
    result=$(bump_version "1.2.3" "major")
    assert_equals "2.0.0" "$result" "bump_version major increments major and resets minor+patch"
}

test_bump_version_zeros() {
    source "$PROJECT_ROOT/bin/lib/version-utils.sh"

    local result
    result=$(bump_version "0.0.0" "patch")
    assert_equals "0.0.1" "$result" "bump_version patch from 0.0.0 gives 0.0.1"
}

test_bump_version_large() {
    source "$PROJECT_ROOT/bin/lib/version-utils.sh"

    local result
    result=$(bump_version "99.99.99" "patch")
    assert_equals "99.99.100" "$result" "bump_version handles large numbers"
}

test_bump_version_minor_resets_patch() {
    source "$PROJECT_ROOT/bin/lib/version-utils.sh"

    local result
    result=$(bump_version "5.3.17" "minor")
    assert_equals "5.4.0" "$result" "bump_version minor resets patch to 0"
}

test_bump_version_major_resets_both() {
    source "$PROJECT_ROOT/bin/lib/version-utils.sh"

    local result
    result=$(bump_version "5.3.17" "major")
    assert_equals "6.0.0" "$result" "bump_version major resets minor and patch to 0"
}

test_bump_version_invalid_type() {
    source "$PROJECT_ROOT/bin/lib/version-utils.sh"

    if bump_version "1.2.3" "invalid" 2>/dev/null; then
        assert_true false "bump_version should reject invalid bump type"
    else
        assert_true true "bump_version correctly rejects invalid bump type"
    fi
}

# ============================================================================
# Test: validate_sha512 function
# ============================================================================
test_validate_sha512_valid() {
    source "$PROJECT_ROOT/bin/lib/version-utils.sh"

    # Valid SHA512 (128 hex characters)
    local valid_sha
    valid_sha="$(printf '%0128d' 0 | command tr '0' 'a')"

    if validate_sha512 "$valid_sha"; then
        assert_true true "validate_sha512 accepts valid 128-character hex"
    else
        assert_true false "validate_sha512 rejected valid SHA512"
    fi
}

test_validate_sha512_uppercase() {
    source "$PROJECT_ROOT/bin/lib/version-utils.sh"

    # Valid SHA512 uppercase (128 hex characters)
    local valid_sha
    valid_sha="$(printf '%0128d' 0 | command tr '0' 'A')"

    if validate_sha512 "$valid_sha"; then
        assert_true true "validate_sha512 accepts uppercase hex"
    else
        assert_true false "validate_sha512 rejected uppercase SHA512"
    fi
}

test_validate_sha512_too_short() {
    source "$PROJECT_ROOT/bin/lib/version-utils.sh"

    # SHA256 length (64 chars) — too short for SHA512
    local short_sha="bda09dc030a08987fe2b3bed678b15b52f23d6705e872d561932d4ca07db7818"

    if validate_sha512 "$short_sha"; then
        assert_true false "validate_sha512 should reject 64-character string"
    else
        assert_true true "validate_sha512 correctly rejects SHA256-length string"
    fi
}

test_validate_sha512_too_long() {
    source "$PROJECT_ROOT/bin/lib/version-utils.sh"

    # 129 hex characters — too long
    local long_sha
    long_sha="$(printf '%0129d' 0 | command tr '0' 'a')"

    if validate_sha512 "$long_sha"; then
        assert_true false "validate_sha512 should reject 129-character string"
    else
        assert_true true "validate_sha512 correctly rejects too-long string"
    fi
}

test_validate_sha512_non_hex() {
    source "$PROJECT_ROOT/bin/lib/version-utils.sh"

    # 128 non-hex characters
    local non_hex
    non_hex="$(printf '%0128d' 0 | command tr '0' 'z')"

    if validate_sha512 "$non_hex"; then
        assert_true false "validate_sha512 should reject non-hex characters"
    else
        assert_true true "validate_sha512 correctly rejects non-hex"
    fi
}

test_validate_sha512_empty() {
    source "$PROJECT_ROOT/bin/lib/version-utils.sh"

    if validate_sha512 ""; then
        assert_true false "validate_sha512 should reject empty string"
    else
        assert_true true "validate_sha512 correctly rejects empty string"
    fi
}

# Run tests
run_test test_validate_version_valid "validate_version accepts valid versions"
run_test test_validate_version_invalid "validate_version rejects invalid versions"
run_test test_validate_version_edge_cases "validate_version handles edge cases"
run_test test_validate_sha256_valid "validate_sha256 accepts valid SHA256"
run_test test_validate_sha256_invalid "validate_sha256 rejects invalid SHA256"
run_test test_version_matches_exact "version_matches handles exact matches"
run_test test_version_matches_partial "version_matches handles partial matches"
run_test test_version_matches_different "version_matches rejects different versions"
run_test test_script_sources_cleanly "Script sources without errors"
run_test test_bump_version_patch "bump_version patch increments patch"
run_test test_bump_version_minor "bump_version minor increments minor"
run_test test_bump_version_major "bump_version major increments major"
run_test test_bump_version_zeros "bump_version handles 0.0.0"
run_test test_bump_version_large "bump_version handles large numbers"
run_test test_bump_version_minor_resets_patch "bump_version minor resets patch"
run_test test_bump_version_major_resets_both "bump_version major resets minor and patch"
run_test test_bump_version_invalid_type "bump_version rejects invalid bump type"
run_test test_validate_sha512_valid "validate_sha512 accepts valid SHA512"
run_test test_validate_sha512_uppercase "validate_sha512 accepts uppercase hex"
run_test test_validate_sha512_too_short "validate_sha512 rejects SHA256-length string"
run_test test_validate_sha512_too_long "validate_sha512 rejects too-long string"
run_test test_validate_sha512_non_hex "validate_sha512 rejects non-hex characters"
run_test test_validate_sha512_empty "validate_sha512 rejects empty string"

# Generate test report
generate_report
