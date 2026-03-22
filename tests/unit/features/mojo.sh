#!/usr/bin/env bash
# Unit tests for lib/features/mojo.sh
# Content-based tests + checksum verification tests

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"
init_test_framework
test_suite "mojo Feature Tests"

# Path to script under test
SOURCE_FILE="$PROJECT_ROOT/lib/features/mojo.sh"

# ============================================================================
# Script Structure Tests
# ============================================================================

test_script_exists_and_executable() {
    assert_file_exists "$SOURCE_FILE"
    [ -x "$SOURCE_FILE" ] \
        && assert_true 0 "mojo.sh is executable" \
        || assert_true 1 "mojo.sh should be executable"
}

test_uses_strict_mode() {
    assert_file_contains "$SOURCE_FILE" "set -euo pipefail" \
        "mojo.sh uses strict mode"
}

test_sources_feature_header() {
    assert_file_contains "$SOURCE_FILE" "source.*feature-header.sh" \
        "mojo.sh sources feature-header.sh"
}

test_log_feature_start() {
    assert_file_contains "$SOURCE_FILE" 'log_feature_start "Mojo"' \
        "mojo.sh logs feature start with correct name"
}

# ============================================================================
# Download & Verification Tests
# ============================================================================

test_sources_checksum_fetch() {
    assert_file_contains "$SOURCE_FILE" "source.*checksum-fetch.sh" \
        "mojo.sh sources checksum-fetch.sh"
}

test_sources_download_verify() {
    assert_file_contains "$SOURCE_FILE" "source.*download-verify.sh" \
        "mojo.sh sources download-verify.sh"
}

test_sources_checksum_verification() {
    assert_file_contains "$SOURCE_FILE" "source.*checksum-verification.sh" \
        "mojo.sh sources checksum-verification.sh"
}

test_sources_cache_utils() {
    assert_file_contains "$SOURCE_FILE" "source.*cache-utils.sh" \
        "mojo.sh sources cache-utils.sh"
}

# ============================================================================
# Pixi Installation Tests
# ============================================================================

test_pixi_installation() {
    assert_file_contains "$SOURCE_FILE" "PIXI_HOME" \
        "mojo.sh configures PIXI_HOME for pixi installation"
}

# ============================================================================
# Configuration Tests
# ============================================================================

test_cache_directories() {
    assert_file_contains "$SOURCE_FILE" "/cache/pixi" \
        "mojo.sh configures /cache/pixi directory"
    assert_file_contains "$SOURCE_FILE" "/cache/mojo" \
        "mojo.sh configures /cache/mojo directory"
}

test_wrapper_scripts() {
    assert_file_contains "$SOURCE_FILE" "/usr/local/bin/mojo" \
        "mojo.sh creates /usr/local/bin/mojo wrapper script"
}

test_bashrc_config() {
    assert_file_contains "$SOURCE_FILE" "60-mojo.sh" \
        "mojo.sh creates 60-mojo.sh bashrc config"
}

# ============================================================================
# Checksum Verification Tests (preserved from original)
# ============================================================================

test_checksum_libraries_sourced() {
    if ! [ -f "$SOURCE_FILE" ]; then
        skip_test "mojo.sh not found"
        return
    fi

    if command grep -q "source.*checksum-fetch.sh" "$SOURCE_FILE"; then
        assert_true true "checksum-fetch.sh library is sourced"
    else
        assert_true false "checksum-fetch.sh library not sourced"
    fi

    if command grep -q "source.*download-verify.sh" "$SOURCE_FILE"; then
        assert_true true "download-verify.sh library is sourced"
    else
        assert_true false "download-verify.sh library not sourced"
    fi
}

test_pixi_checksum_fetching() {
    if ! [ -f "$SOURCE_FILE" ]; then
        skip_test "mojo.sh not found"
        return
    fi

    if command grep -q 'register_tool_checksum_fetcher.*pixi' "$SOURCE_FILE"; then
        assert_true true "Uses register_tool_checksum_fetcher for pixi"
    else
        assert_true false "Does not use register_tool_checksum_fetcher for pixi"
    fi
}

test_download_verification() {
    if ! [ -f "$SOURCE_FILE" ]; then
        skip_test "mojo.sh not found"
        return
    fi

    if command grep -q "verify_download" "$SOURCE_FILE"; then
        assert_true true "Uses verify_download for checksum verification"
    else
        assert_true false "Does not use verify_download"
    fi
}

# Content-based tests
run_test test_script_exists_and_executable "Script exists and is executable"
run_test test_uses_strict_mode "Uses set -euo pipefail"
run_test test_sources_feature_header "Sources feature-header.sh"
run_test test_log_feature_start "Logs feature start with correct name"
run_test test_sources_checksum_fetch "Sources checksum-fetch.sh"
run_test test_sources_download_verify "Sources download-verify.sh"
run_test test_sources_checksum_verification "Sources checksum-verification.sh"
run_test test_sources_cache_utils "Sources cache-utils.sh"
run_test test_pixi_installation "Pixi installation (PIXI_HOME)"
run_test test_cache_directories "Cache directories (/cache/pixi, /cache/mojo)"
run_test test_wrapper_scripts "Wrapper scripts (/usr/local/bin/mojo)"
run_test test_bashrc_config "Bashrc config (60-mojo.sh)"

# Checksum verification tests
run_test test_checksum_libraries_sourced "Checksum libraries are sourced"
run_test test_pixi_checksum_fetching "Pixi checksum fetching is used"
run_test test_download_verification "Download verification is used"

generate_report
