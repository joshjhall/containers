#!/usr/bin/env bash
# Unit tests for lib/features/ollama.sh
# Content-based tests that verify the source script structure

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"
init_test_framework
test_suite "ollama Feature Tests"

# Path to script under test
SOURCE_FILE="$PROJECT_ROOT/lib/features/ollama.sh"

# ============================================================================
# Script Structure Tests
# ============================================================================

test_script_exists_and_executable() {
    assert_file_exists "$SOURCE_FILE"
    [ -x "$SOURCE_FILE" ] \
        && assert_true 0 "ollama.sh is executable" \
        || assert_true 1 "ollama.sh should be executable"
}

test_uses_strict_mode() {
    assert_file_contains "$SOURCE_FILE" "set -euo pipefail" \
        "ollama.sh uses strict mode"
}

test_sources_feature_header() {
    assert_file_contains "$SOURCE_FILE" "source.*feature-header.sh" \
        "ollama.sh sources feature-header.sh"
}

test_log_feature_start() {
    assert_file_contains "$SOURCE_FILE" 'log_feature_start "Ollama"' \
        "ollama.sh logs feature start with correct name"
}

# ============================================================================
# Download & Verification Tests
# ============================================================================

test_sources_download_verify() {
    assert_file_contains "$SOURCE_FILE" "source.*download-verify.sh" \
        "ollama.sh sources download-verify.sh"
}

test_sources_checksum_fetch() {
    assert_file_contains "$SOURCE_FILE" "source.*checksum-fetch.sh" \
        "ollama.sh sources checksum-fetch.sh"
}

test_sources_checksum_verification() {
    assert_file_contains "$SOURCE_FILE" "source.*checksum-verification.sh" \
        "ollama.sh sources checksum-verification.sh"
}

test_architecture_support() {
    assert_file_contains "$SOURCE_FILE" "map_arch_or_skip" \
        "ollama.sh uses map_arch_or_skip for architecture detection"
}

test_checksum_fetcher_registered() {
    assert_file_contains "$SOURCE_FILE" "register_tool_checksum_fetcher.*ollama" \
        "ollama.sh registers checksum fetcher for ollama"
}

test_uses_verify_download() {
    assert_file_contains "$SOURCE_FILE" "verify_download" \
        "ollama.sh uses verify_download for checksum verification"
}

# ============================================================================
# Configuration Tests
# ============================================================================

test_cache_directory_configuration() {
    assert_file_contains "$SOURCE_FILE" "/cache/ollama" \
        "ollama.sh configures /cache/ollama model directory"
    assert_file_contains "$SOURCE_FILE" "OLLAMA_MODELS" \
        "ollama.sh references OLLAMA_MODELS environment variable"
}

test_helper_scripts() {
    assert_file_contains "$SOURCE_FILE" "start-ollama" \
        "ollama.sh creates start-ollama helper script"
}

test_bashrc_config() {
    assert_file_contains "$SOURCE_FILE" "70-ollama.sh" \
        "ollama.sh creates 70-ollama.sh bashrc config"
}

run_test test_script_exists_and_executable "Script exists and is executable"
run_test test_uses_strict_mode "Uses set -euo pipefail"
run_test test_sources_feature_header "Sources feature-header.sh"
run_test test_log_feature_start "Logs feature start with correct name"
run_test test_sources_download_verify "Sources download-verify.sh"
run_test test_sources_checksum_fetch "Sources checksum-fetch.sh"
run_test test_sources_checksum_verification "Sources checksum-verification.sh"
run_test test_architecture_support "Architecture support (map_arch_or_skip)"
run_test test_checksum_fetcher_registered "Checksum fetcher registered for ollama"
run_test test_uses_verify_download "Uses verify_download for verification"
run_test test_cache_directory_configuration "Cache directory configuration"
run_test test_helper_scripts "Helper scripts (start-ollama)"
run_test test_bashrc_config "Bashrc config (70-ollama.sh)"

generate_report
