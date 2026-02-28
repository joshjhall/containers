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

# Generate test report
generate_report
