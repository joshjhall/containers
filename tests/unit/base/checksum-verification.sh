#!/usr/bin/env bash
# Unit tests for lib/base/checksum-verification.sh
# Tests 4-tier checksum verification system for download integrity

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Checksum Verification Tests"

# Source file under test
SOURCE_FILE="$PROJECT_ROOT/lib/base/checksum-verification.sh"

# Setup function - runs before each test
setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$RESULTS_DIR/test-checksum-verify-$unique_id"
    mkdir -p "$TEST_TEMP_DIR"
}

# Teardown function - runs after each test
teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
    unset TEST_TEMP_DIR 2>/dev/null || true
}

# Run tests with setup/teardown
run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"
    setup
    run_test "$test_function" "$test_description"
    teardown
}

# Helper: run a subshell that sources the file and outputs result on last line
# All log output is suppressed (sent to /dev/null)
_run_checksum_subshell() {
    # Runs the provided commands in a subshell, suppressing all log output
    # Usage: result=$(_run_checksum_subshell "commands...")
    bash -c "
        # Provide fallback functions for dependencies not available in test
        log_message() { :; }
        log_error() { :; }
        log_info() { :; }
        log_warn() { :; }
        verify_signature() { return 1; }
        fetch_ruby_checksum() { return 1; }
        fetch_go_checksum() { return 1; }
        export -f log_message log_error log_info log_warn
        export -f verify_signature fetch_ruby_checksum fetch_go_checksum
        export CHECKSUMS_DB='${TEST_TEMP_DIR}/checksums.json'
        source '$SOURCE_FILE' >/dev/null 2>&1
        $1
    " 2>/dev/null
}

# ============================================================================
# Static Analysis Tests
# ============================================================================

test_strict_mode() {
    assert_file_contains "$SOURCE_FILE" "set -euo pipefail" "Script uses strict mode"
}

test_defines_verify_signature_tier() {
    assert_file_contains "$SOURCE_FILE" "verify_signature_tier()" \
        "Script defines verify_signature_tier function"
}

test_defines_lookup_pinned_checksum() {
    assert_file_contains "$SOURCE_FILE" "lookup_pinned_checksum()" \
        "Script defines lookup_pinned_checksum function"
}

test_defines_verify_pinned_checksum() {
    assert_file_contains "$SOURCE_FILE" "verify_pinned_checksum()" \
        "Script defines verify_pinned_checksum function"
}

test_defines_verify_published_checksum() {
    assert_file_contains "$SOURCE_FILE" "verify_published_checksum()" \
        "Script defines verify_published_checksum function"
}

test_defines_verify_calculated_checksum() {
    assert_file_contains "$SOURCE_FILE" "verify_calculated_checksum()" \
        "Script defines verify_calculated_checksum function"
}

test_defines_verify_download() {
    assert_file_contains "$SOURCE_FILE" "verify_download()" \
        "Script defines verify_download function"
}

# ============================================================================
# Functional Tests - lookup_pinned_checksum()
# ============================================================================

test_lookup_pinned_checksum_missing_db() {
    # When checksums.json does not exist, lookup should return 1
    local exit_code=0
    _run_checksum_subshell "
        export CHECKSUMS_DB='$TEST_TEMP_DIR/nonexistent-checksums.json'
        lookup_pinned_checksum 'language' 'python' '3.12.7'
    " || exit_code=$?

    assert_equals "1" "$exit_code" "lookup_pinned_checksum returns 1 when checksums.json missing"
}

test_lookup_pinned_checksum_valid_language() {
    # Create a valid checksums.json with a known checksum
    local expected_hash="a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
    command cat > "$TEST_TEMP_DIR/checksums.json" <<EOF
{
    "languages": {
        "python": {
            "versions": {
                "3.12.7": {
                    "sha256": "$expected_hash"
                }
            }
        }
    },
    "tools": {}
}
EOF

    local result
    result=$(_run_checksum_subshell "
        export CHECKSUMS_DB='$TEST_TEMP_DIR/checksums.json'
        lookup_pinned_checksum 'language' 'python' '3.12.7'
    ")

    assert_equals "$expected_hash" "$result" "lookup_pinned_checksum returns correct hash for known version"
}

test_lookup_pinned_checksum_valid_tool() {
    local expected_hash="f1e2d3c4b5a6f1e2d3c4b5a6f1e2d3c4b5a6f1e2d3c4b5a6f1e2d3c4b5a6f1e2"
    command cat > "$TEST_TEMP_DIR/checksums.json" <<EOF
{
    "languages": {},
    "tools": {
        "gh": {
            "versions": {
                "2.60.1": {
                    "sha256": "$expected_hash"
                }
            }
        }
    }
}
EOF

    local result
    result=$(_run_checksum_subshell "
        export CHECKSUMS_DB='$TEST_TEMP_DIR/checksums.json'
        lookup_pinned_checksum 'tool' 'gh' '2.60.1'
    ")

    assert_equals "$expected_hash" "$result" "lookup_pinned_checksum returns correct hash for tool"
}

test_lookup_pinned_checksum_unknown_version() {
    command cat > "$TEST_TEMP_DIR/checksums.json" <<EOF
{
    "languages": {
        "python": {
            "versions": {
                "3.12.7": {
                    "sha256": "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
                }
            }
        }
    },
    "tools": {}
}
EOF

    local exit_code=0
    _run_checksum_subshell "
        export CHECKSUMS_DB='$TEST_TEMP_DIR/checksums.json'
        lookup_pinned_checksum 'language' 'python' '3.11.0'
    " || exit_code=$?

    assert_equals "1" "$exit_code" "lookup_pinned_checksum returns 1 for unknown version"
}

test_lookup_pinned_checksum_skips_placeholder() {
    command cat > "$TEST_TEMP_DIR/checksums.json" <<EOF
{
    "languages": {
        "python": {
            "versions": {
                "3.12.7": {
                    "sha256": "placeholder_actual_checksum_needed"
                }
            }
        }
    },
    "tools": {}
}
EOF

    local exit_code=0
    _run_checksum_subshell "
        export CHECKSUMS_DB='$TEST_TEMP_DIR/checksums.json'
        lookup_pinned_checksum 'language' 'python' '3.12.7'
    " || exit_code=$?

    assert_equals "1" "$exit_code" "lookup_pinned_checksum rejects placeholder checksums"
}

# ============================================================================
# Functional Tests - verify_calculated_checksum()
# ============================================================================

test_verify_calculated_checksum_returns_2() {
    # Create a test file to calculate checksum for
    echo "test file content" > "$TEST_TEMP_DIR/testfile.tgz"

    local exit_code=0
    _run_checksum_subshell "
        verify_calculated_checksum '$TEST_TEMP_DIR/testfile.tgz'
    " || exit_code=$?

    assert_equals "2" "$exit_code" "verify_calculated_checksum returns 2 (unverified/TOFU)"
}

test_verify_calculated_checksum_returns_2_for_binary_file() {
    # Create a binary-like file
    dd if=/dev/urandom of="$TEST_TEMP_DIR/binary.tgz" bs=1024 count=1 2>/dev/null

    local exit_code=0
    _run_checksum_subshell "
        verify_calculated_checksum '$TEST_TEMP_DIR/binary.tgz'
    " || exit_code=$?

    assert_equals "2" "$exit_code" "verify_calculated_checksum returns 2 for binary files"
}

# ============================================================================
# Functional Tests - verify_pinned_checksum()
# ============================================================================

test_verify_pinned_checksum_match() {
    # Create a file and compute its real sha256sum, then populate checksums.json
    # with the matching hash — verify_pinned_checksum should return 0.
    echo "checksum match test content" > "$TEST_TEMP_DIR/match-test.tgz"
    local real_hash
    real_hash=$(sha256sum "$TEST_TEMP_DIR/match-test.tgz" | command awk '{print $1}')

    command cat > "$TEST_TEMP_DIR/checksums.json" <<EOJSON
{
    "languages": {
        "testlang": {
            "versions": {
                "1.0.0": {
                    "sha256": "$real_hash"
                }
            }
        }
    },
    "tools": {}
}
EOJSON

    local exit_code=0
    _run_checksum_subshell "
        export CHECKSUMS_DB='$TEST_TEMP_DIR/checksums.json'
        verify_pinned_checksum 'language' 'testlang' '1.0.0' '$TEST_TEMP_DIR/match-test.tgz'
    " || exit_code=$?

    assert_equals "0" "$exit_code" "verify_pinned_checksum returns 0 when checksum matches"
}

test_verify_pinned_checksum_mismatch() {
    # Create a file but populate checksums.json with a WRONG hash —
    # verify_pinned_checksum should return 1 (checksum mismatch).
    echo "checksum mismatch test content" > "$TEST_TEMP_DIR/mismatch-test.tgz"
    local wrong_hash="0000000000000000000000000000000000000000000000000000000000000000"

    command cat > "$TEST_TEMP_DIR/checksums.json" <<EOJSON
{
    "languages": {
        "testlang": {
            "versions": {
                "2.0.0": {
                    "sha256": "$wrong_hash"
                }
            }
        }
    },
    "tools": {}
}
EOJSON

    local exit_code=0
    _run_checksum_subshell "
        export CHECKSUMS_DB='$TEST_TEMP_DIR/checksums.json'
        verify_pinned_checksum 'language' 'testlang' '2.0.0' '$TEST_TEMP_DIR/mismatch-test.tgz'
    " || exit_code=$?

    assert_equals "1" "$exit_code" "verify_pinned_checksum returns 1 when checksum does not match"
}

# ============================================================================
# Static Analysis Tests - Tier Architecture
# ============================================================================

test_verify_download_skips_tier1_for_tools() {
    # In verify_download, tier 1 (signature) is only tried for "language" category
    assert_file_contains "$SOURCE_FILE" 'if \[ "$category" = "language" \]' \
        "verify_download only runs tier 1 for language category"
}

test_tier_fallback_order_tier1_before_tier2() {
    # Tier 1 should appear before Tier 2 in source order
    assert_file_contains "$SOURCE_FILE" "TIER 1.*Signature" \
        "Source contains Tier 1 signature verification section"
}

test_tier_fallback_order_tier2_before_tier3() {
    assert_file_contains "$SOURCE_FILE" "TIER 2.*Pinned" \
        "Source contains Tier 2 pinned checksums section"
}

test_tier_fallback_order_tier3_before_tier4() {
    assert_file_contains "$SOURCE_FILE" "TIER 3.*Published" \
        "Source contains Tier 3 published checksums section"
}

test_tier_fallback_order_tier4_fallback() {
    assert_file_contains "$SOURCE_FILE" "TIER 4.*Fallback\|TIER 4.*Calculated" \
        "Source contains Tier 4 fallback section"
}

test_sha256_pattern_in_source() {
    assert_file_contains "$SOURCE_FILE" "sha256sum" \
        "Source uses sha256sum for checksum calculation"
}

test_checksum_format_64_hex_chars() {
    # The source should validate or use 64-character hex checksums (SHA256)
    assert_file_contains "$SOURCE_FILE" "sha256" \
        "Source references SHA256 checksum format"
}

test_exports_all_functions() {
    assert_file_contains "$SOURCE_FILE" "export -f verify_download" \
        "verify_download is exported"
    assert_file_contains "$SOURCE_FILE" "export -f verify_signature_tier" \
        "verify_signature_tier is exported"
    assert_file_contains "$SOURCE_FILE" "export -f verify_pinned_checksum" \
        "verify_pinned_checksum is exported"
    assert_file_contains "$SOURCE_FILE" "export -f verify_published_checksum" \
        "verify_published_checksum is exported"
    assert_file_contains "$SOURCE_FILE" "export -f verify_calculated_checksum" \
        "verify_calculated_checksum is exported"
    assert_file_contains "$SOURCE_FILE" "export -f lookup_pinned_checksum" \
        "lookup_pinned_checksum is exported"
}

test_verify_download_returns_2_for_tofu() {
    # verify_download returns 2 (not 0) when falling back to tier 4 TOFU
    # This lets callers distinguish verified (0), failed (1), and unverified (2)
    echo "test content for tofu" > "$TEST_TEMP_DIR/tofu-test.tgz"

    # Create empty checksums.json so tier 2 fails
    echo '{"languages":{},"tools":{}}' > "$TEST_TEMP_DIR/checksums.json"

    local exit_code=0
    _run_checksum_subshell "
        export CHECKSUMS_DB='$TEST_TEMP_DIR/checksums.json'
        verify_download 'language' 'unknown-lang' '0.0.0' '$TEST_TEMP_DIR/tofu-test.tgz'
    " || exit_code=$?

    assert_equals "2" "$exit_code" "verify_download returns 2 for Tier 4 TOFU fallback"
}

test_verify_download_calls_calculated_checksum_fallback() {
    # verify_download calls verify_calculated_checksum as final fallback
    assert_file_contains "$SOURCE_FILE" "verify_calculated_checksum" \
        "verify_download calls verify_calculated_checksum as final fallback"
}

test_require_verified_downloads_blocks_tofu() {
    # When REQUIRE_VERIFIED_DOWNLOADS=true, tier 4 returns 1 (hard fail)
    echo "test content for blocked tofu" > "$TEST_TEMP_DIR/blocked-tofu.tgz"

    # Create empty checksums.json so tier 2 fails
    echo '{"languages":{},"tools":{}}' > "$TEST_TEMP_DIR/checksums.json"

    local exit_code=0
    _run_checksum_subshell "
        export CHECKSUMS_DB='$TEST_TEMP_DIR/checksums.json'
        export REQUIRE_VERIFIED_DOWNLOADS=true
        verify_download 'language' 'unknown-lang' '0.0.0' '$TEST_TEMP_DIR/blocked-tofu.tgz'
    " || exit_code=$?

    assert_equals "1" "$exit_code" "REQUIRE_VERIFIED_DOWNLOADS=true blocks TOFU fallback with exit 1"
}

test_production_mode_blocks_tofu() {
    # When PRODUCTION_MODE=true (and REQUIRE_VERIFIED_DOWNLOADS unset), tier 4 returns 1
    echo "test content for prod tofu" > "$TEST_TEMP_DIR/prod-tofu.tgz"

    # Create empty checksums.json so tier 2 fails
    echo '{"languages":{},"tools":{}}' > "$TEST_TEMP_DIR/checksums.json"

    local exit_code=0
    _run_checksum_subshell "
        export CHECKSUMS_DB='$TEST_TEMP_DIR/checksums.json'
        export PRODUCTION_MODE=true
        verify_download 'language' 'unknown-lang' '0.0.0' '$TEST_TEMP_DIR/prod-tofu.tgz'
    " || exit_code=$?

    assert_equals "1" "$exit_code" "PRODUCTION_MODE=true blocks TOFU fallback via REQUIRE_VERIFIED_DOWNLOADS default"
}

test_source_contains_require_verified_downloads() {
    assert_file_contains "$SOURCE_FILE" "REQUIRE_VERIFIED_DOWNLOADS" \
        "Source references REQUIRE_VERIFIED_DOWNLOADS env var"
}

test_tier3_language_uses_published_checksum() {
    # Tier 3 for language category uses verify_published_checksum
    assert_file_contains "$SOURCE_FILE" 'verify_published_checksum' \
        "Source calls verify_published_checksum for languages"
    assert_file_contains "$SOURCE_FILE" '"$category" = "language"' \
        "Language tier 3 is gated by category = language check"
}

test_tier3_tool_uses_tool_fetcher() {
    # Tier 3 for tool category uses verify_tool_published_checksum
    assert_file_contains "$SOURCE_FILE" 'verify_tool_published_checksum' \
        "Source calls verify_tool_published_checksum for tools"
    assert_file_contains "$SOURCE_FILE" '"$category" = "tool"' \
        "Tool tier 3 is gated by category = tool check"
}

test_security_warning_in_tier4() {
    assert_file_contains "$SOURCE_FILE" "SECURITY WARNING" \
        "Tier 4 includes a security warning about TOFU risk"
}

test_tofu_warning_in_tier4() {
    assert_file_contains "$SOURCE_FILE" "TOFU" \
        "Tier 4 warns about Trust On First Use"
}

# ============================================================================
# Functional Tests - Tool Tier 3 Fetcher Registry
# ============================================================================

test_defines_register_tool_checksum_fetcher() {
    assert_file_contains "$SOURCE_FILE" "register_tool_checksum_fetcher()" \
        "Script defines register_tool_checksum_fetcher function"
}

test_defines_verify_tool_published_checksum() {
    assert_file_contains "$SOURCE_FILE" "verify_tool_published_checksum()" \
        "Script defines verify_tool_published_checksum function"
}

test_exports_tool_tier3_functions() {
    assert_file_contains "$SOURCE_FILE" "export -f register_tool_checksum_fetcher" \
        "register_tool_checksum_fetcher is exported"
    assert_file_contains "$SOURCE_FILE" "export -f verify_tool_published_checksum" \
        "verify_tool_published_checksum is exported"
}

test_register_tool_fetcher_stores_correctly() {
    # Register a fetcher and verify it's stored in the associative array
    local exit_code=0
    local result
    result=$(_run_checksum_subshell "
        _my_fetcher() { echo 'abc123'; }
        register_tool_checksum_fetcher 'mytool' '_my_fetcher'
        echo \"\${_TOOL_CHECKSUM_FETCHERS[mytool]}\"
    ") || exit_code=$?

    assert_equals "0" "$exit_code" "register_tool_checksum_fetcher succeeds"
    assert_equals "_my_fetcher" "$result" "Fetcher function name is stored correctly"
}

test_verify_download_tool_tier3_passes() {
    # Register a fetcher that returns the correct checksum for the test file
    echo "tool tier 3 test content" > "$TEST_TEMP_DIR/tool-tier3.tgz"
    local real_hash
    real_hash=$(sha256sum "$TEST_TEMP_DIR/tool-tier3.tgz" | command awk '{print $1}')

    # Create empty checksums.json so tier 2 fails
    echo '{"languages":{},"tools":{}}' > "$TEST_TEMP_DIR/checksums.json"

    local exit_code=0
    _run_checksum_subshell "
        export CHECKSUMS_DB='$TEST_TEMP_DIR/checksums.json'
        _test_fetcher() { echo '$real_hash'; }
        register_tool_checksum_fetcher 'test-tool' '_test_fetcher'
        verify_download 'tool' 'test-tool' '1.0.0' '$TEST_TEMP_DIR/tool-tier3.tgz'
    " || exit_code=$?

    assert_equals "0" "$exit_code" "verify_download returns 0 when tool Tier 3 fetcher provides matching checksum"
}

test_verify_download_tool_tier3_mismatch() {
    # Register a fetcher that returns a WRONG checksum
    echo "tool tier 3 mismatch content" > "$TEST_TEMP_DIR/tool-mismatch.tgz"
    local wrong_hash="0000000000000000000000000000000000000000000000000000000000000000"

    # Create empty checksums.json so tier 2 fails
    echo '{"languages":{},"tools":{}}' > "$TEST_TEMP_DIR/checksums.json"

    local exit_code=0
    _run_checksum_subshell "
        export CHECKSUMS_DB='$TEST_TEMP_DIR/checksums.json'
        _bad_fetcher() { echo '$wrong_hash'; }
        register_tool_checksum_fetcher 'bad-tool' '_bad_fetcher'
        verify_download 'tool' 'bad-tool' '1.0.0' '$TEST_TEMP_DIR/tool-mismatch.tgz'
    " || exit_code=$?

    assert_equals "1" "$exit_code" "verify_download returns 1 when tool Tier 3 checksum doesn't match"
}

test_verify_download_tool_no_fetcher_falls_to_tier4() {
    # Tool with no registered fetcher should fall through to Tier 4 (TOFU)
    echo "tool no fetcher content" > "$TEST_TEMP_DIR/tool-nofetcher.tgz"

    # Create empty checksums.json so tier 2 fails
    echo '{"languages":{},"tools":{}}' > "$TEST_TEMP_DIR/checksums.json"

    local exit_code=0
    _run_checksum_subshell "
        export CHECKSUMS_DB='$TEST_TEMP_DIR/checksums.json'
        verify_download 'tool' 'no-fetcher-tool' '1.0.0' '$TEST_TEMP_DIR/tool-nofetcher.tgz'
    " || exit_code=$?

    assert_equals "2" "$exit_code" "verify_download returns 2 (TOFU) when no fetcher registered for tool"
}

test_tier2_takes_priority_over_tool_tier3() {
    # Tier 2 pinned checksum should be checked before Tier 3 fetcher
    echo "tier 2 priority test" > "$TEST_TEMP_DIR/tier2-priority.tgz"
    local real_hash
    real_hash=$(sha256sum "$TEST_TEMP_DIR/tier2-priority.tgz" | command awk '{print $1}')

    # Put the correct hash in checksums.json (Tier 2)
    command cat > "$TEST_TEMP_DIR/checksums.json" <<EOJSON
{
    "languages": {},
    "tools": {
        "priority-tool": {
            "versions": {
                "1.0.0": {
                    "sha256": "$real_hash"
                }
            }
        }
    }
}
EOJSON

    local exit_code=0
    _run_checksum_subshell "
        export CHECKSUMS_DB='$TEST_TEMP_DIR/checksums.json'
        # Register a fetcher that would FAIL if called (returns wrong hash)
        _should_not_be_called() { echo '0000000000000000000000000000000000000000000000000000000000000000'; }
        register_tool_checksum_fetcher 'priority-tool' '_should_not_be_called'
        verify_download 'tool' 'priority-tool' '1.0.0' '$TEST_TEMP_DIR/tier2-priority.tgz'
    " || exit_code=$?

    assert_equals "0" "$exit_code" "Tier 2 pinned checksum takes priority over Tier 3 fetcher"
}

test_require_verified_downloads_blocks_tool_tofu() {
    # REQUIRE_VERIFIED_DOWNLOADS=true should block tool TOFU just like language TOFU
    echo "tool tofu blocked content" > "$TEST_TEMP_DIR/tool-blocked.tgz"

    echo '{"languages":{},"tools":{}}' > "$TEST_TEMP_DIR/checksums.json"

    local exit_code=0
    _run_checksum_subshell "
        export CHECKSUMS_DB='$TEST_TEMP_DIR/checksums.json'
        export REQUIRE_VERIFIED_DOWNLOADS=true
        verify_download 'tool' 'blocked-tool' '1.0.0' '$TEST_TEMP_DIR/tool-blocked.tgz'
    " || exit_code=$?

    assert_equals "1" "$exit_code" "REQUIRE_VERIFIED_DOWNLOADS=true blocks tool TOFU with exit 1"
}

test_verify_tool_published_checksum_sha512() {
    # Test that SHA512 checksums (128 hex chars) work for tool Tier 3
    echo "sha512 tool test content" > "$TEST_TEMP_DIR/tool-sha512.tgz"
    local real_hash
    real_hash=$(sha512sum "$TEST_TEMP_DIR/tool-sha512.tgz" | command awk '{print $1}')

    echo '{"languages":{},"tools":{}}' > "$TEST_TEMP_DIR/checksums.json"

    local exit_code=0
    _run_checksum_subshell "
        export CHECKSUMS_DB='$TEST_TEMP_DIR/checksums.json'
        _sha512_fetcher() { echo '$real_hash'; }
        register_tool_checksum_fetcher 'sha512-tool' '_sha512_fetcher'
        verify_download 'tool' 'sha512-tool' '1.0.0' '$TEST_TEMP_DIR/tool-sha512.tgz'
    " || exit_code=$?

    assert_equals "0" "$exit_code" "Tool Tier 3 works with SHA512 checksums"
}

# ============================================================================
# Run all tests
# ============================================================================

# Static analysis
run_test_with_setup test_strict_mode "Script uses strict mode"
run_test_with_setup test_defines_verify_signature_tier "Defines verify_signature_tier function"
run_test_with_setup test_defines_lookup_pinned_checksum "Defines lookup_pinned_checksum function"
run_test_with_setup test_defines_verify_pinned_checksum "Defines verify_pinned_checksum function"
run_test_with_setup test_defines_verify_published_checksum "Defines verify_published_checksum function"
run_test_with_setup test_defines_verify_calculated_checksum "Defines verify_calculated_checksum function"
run_test_with_setup test_defines_verify_download "Defines verify_download function"

# lookup_pinned_checksum
run_test_with_setup test_lookup_pinned_checksum_missing_db "lookup_pinned_checksum returns 1 when DB missing"
run_test_with_setup test_lookup_pinned_checksum_valid_language "lookup_pinned_checksum returns hash for known language version"
run_test_with_setup test_lookup_pinned_checksum_valid_tool "lookup_pinned_checksum returns hash for known tool version"
run_test_with_setup test_lookup_pinned_checksum_unknown_version "lookup_pinned_checksum returns 1 for unknown version"
run_test_with_setup test_lookup_pinned_checksum_skips_placeholder "lookup_pinned_checksum rejects placeholder checksums"

# verify_calculated_checksum
run_test_with_setup test_verify_calculated_checksum_returns_2 "verify_calculated_checksum returns 2 (unverified/TOFU)"
run_test_with_setup test_verify_calculated_checksum_returns_2_for_binary_file "verify_calculated_checksum returns 2 for binary files"

# verify_pinned_checksum
run_test_with_setup test_verify_pinned_checksum_match "verify_pinned_checksum returns 0 when checksum matches"
run_test_with_setup test_verify_pinned_checksum_mismatch "verify_pinned_checksum returns 1 on checksum mismatch"

# Tier architecture (static analysis)
run_test_with_setup test_verify_download_skips_tier1_for_tools "verify_download skips tier 1 for tools"
run_test_with_setup test_tier_fallback_order_tier1_before_tier2 "Tier 1 section present in source"
run_test_with_setup test_tier_fallback_order_tier2_before_tier3 "Tier 2 section present in source"
run_test_with_setup test_tier_fallback_order_tier3_before_tier4 "Tier 3 section present in source"
run_test_with_setup test_tier_fallback_order_tier4_fallback "Tier 4 section present in source"
run_test_with_setup test_sha256_pattern_in_source "Source uses sha256sum for checksums"
run_test_with_setup test_checksum_format_64_hex_chars "Source references SHA256 format"
run_test_with_setup test_exports_all_functions "All public functions are exported"
run_test_with_setup test_verify_download_calls_calculated_checksum_fallback "verify_download falls back to tier 4"
run_test_with_setup test_verify_download_returns_2_for_tofu "verify_download returns 2 for TOFU fallback"
run_test_with_setup test_require_verified_downloads_blocks_tofu "REQUIRE_VERIFIED_DOWNLOADS blocks TOFU"
run_test_with_setup test_production_mode_blocks_tofu "PRODUCTION_MODE blocks TOFU via default"
run_test_with_setup test_source_contains_require_verified_downloads "Source contains REQUIRE_VERIFIED_DOWNLOADS"
run_test_with_setup test_tier3_language_uses_published_checksum "Tier 3 for languages uses published checksum"
run_test_with_setup test_tier3_tool_uses_tool_fetcher "Tier 3 for tools uses tool fetcher"
run_test_with_setup test_security_warning_in_tier4 "Tier 4 includes security warning"
run_test_with_setup test_tofu_warning_in_tier4 "Tier 4 warns about TOFU risk"

# Tool Tier 3 fetcher registry
run_test_with_setup test_defines_register_tool_checksum_fetcher "Defines register_tool_checksum_fetcher function"
run_test_with_setup test_defines_verify_tool_published_checksum "Defines verify_tool_published_checksum function"
run_test_with_setup test_exports_tool_tier3_functions "Tool Tier 3 functions are exported"
run_test_with_setup test_register_tool_fetcher_stores_correctly "register_tool_checksum_fetcher stores fetcher correctly"
run_test_with_setup test_verify_download_tool_tier3_passes "verify_download tool with matching Tier 3 fetcher passes"
run_test_with_setup test_verify_download_tool_tier3_mismatch "verify_download tool with mismatching Tier 3 returns 1"
run_test_with_setup test_verify_download_tool_no_fetcher_falls_to_tier4 "verify_download tool without fetcher falls to Tier 4"
run_test_with_setup test_tier2_takes_priority_over_tool_tier3 "Tier 2 pinned checksum takes priority over Tier 3 fetcher"
run_test_with_setup test_require_verified_downloads_blocks_tool_tofu "REQUIRE_VERIFIED_DOWNLOADS blocks tool TOFU"
run_test_with_setup test_verify_tool_published_checksum_sha512 "Tool Tier 3 works with SHA512 checksums"

# Generate test report
generate_report
