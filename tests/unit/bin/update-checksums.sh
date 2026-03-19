#!/usr/bin/env bash
# Unit tests for bin/update-checksums.sh
# Tests checksum update script structure and content via static analysis

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Bin Update Checksums Tests"

SOURCE_FILE="$PROJECT_ROOT/bin/update-checksums.sh"

# Setup function - runs before each test
setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$RESULTS_DIR/test-update-checksums-$unique_id"
    mkdir -p "$TEST_TEMP_DIR"
}

# Teardown function - runs after each test
teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
    unset TEST_TEMP_DIR 2>/dev/null || true
}

# Wrapper for running tests with setup/teardown
run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"

    setup
    run_test "$test_function" "$test_description"
    teardown
}

# ---------------------------------------------------------------------------
# Static analysis tests: Script structure
# ---------------------------------------------------------------------------

# Test: Script uses strict mode
test_checksums_strict_mode() {
    assert_file_contains "$SOURCE_FILE" "set -euo pipefail" \
        "update-checksums.sh should use strict mode"
}

# Test: Script defines update_checksum function
test_checksums_defines_update_checksum() {
    assert_file_contains "$SOURCE_FILE" "update_checksum()" \
        "Should define update_checksum function"
}

# Test: Script sources bin/lib/common.sh
test_checksums_sources_common() {
    assert_file_contains "$SOURCE_FILE" 'lib/common.sh' \
        "Should source common.sh utilities"
}

# Test: Script sources or references checksum-fetch.sh
test_checksums_sources_checksum_fetch() {
    assert_file_contains "$SOURCE_FILE" "checksum-fetch.sh" \
        "Should source or reference lib/base/checksum-fetch.sh"
}

# ---------------------------------------------------------------------------
# Static analysis tests: Configuration and paths
# ---------------------------------------------------------------------------

# Test: CHECKSUMS_FILE references lib/checksums.json
test_checksums_file_path() {
    assert_file_contains "$SOURCE_FILE" "lib/checksums.json" \
        "CHECKSUMS_FILE should reference lib/checksums.json"
}

# Test: DRY_RUN variable initialization
test_checksums_dry_run_variable() {
    assert_file_contains "$SOURCE_FILE" "DRY_RUN=false" \
        "DRY_RUN should be initialized to false"
}

# Test: --dry-run flag handling
test_checksums_dry_run_flag() {
    assert_file_contains "$SOURCE_FILE" "DRY_RUN=true" \
        "Should set DRY_RUN=true when --dry-run flag is used"
}

# Test: --help flag handling
test_checksums_help_flag() {
    assert_file_contains "$SOURCE_FILE" "help)" \
        "Should handle --help flag"
}

# ---------------------------------------------------------------------------
# Static analysis tests: Backup and validation
# ---------------------------------------------------------------------------

# Test: Creates backup file with timestamp pattern
test_checksums_backup_file() {
    assert_file_contains "$SOURCE_FILE" ".backup-" \
        "Should create backup file with timestamp pattern"
}

# Test: SHA256 validation pattern (64 hex chars)
test_checksums_sha256_validation() {
    assert_file_contains "$SOURCE_FILE" "a-fA-F0-9" \
        "Should validate SHA256 checksum format with hex character class"
}

# Test: Processes nodejs language
test_checksums_processes_nodejs() {
    assert_file_contains "$SOURCE_FILE" "nodejs" \
        "Should process nodejs language checksums"
}

# Test: Processes golang language
test_checksums_processes_golang() {
    assert_file_contains "$SOURCE_FILE" "golang" \
        "Should process golang language checksums"
}

# Test: Processes ruby language
test_checksums_processes_ruby() {
    assert_file_contains "$SOURCE_FILE" "ruby" \
        "Should process ruby language checksums"
}

# ---------------------------------------------------------------------------
# Static analysis tests: Metadata and JSON handling
# ---------------------------------------------------------------------------

# Test: Updates metadata.generated timestamp
test_checksums_updates_metadata_timestamp() {
    assert_file_contains "$SOURCE_FILE" "metadata.generated" \
        "Should update metadata.generated timestamp"
}

# Test: Validates JSON with jq empty
test_checksums_validates_json() {
    assert_file_contains "$SOURCE_FILE" "jq empty" \
        "Should validate JSON with jq empty"
}

# Test: UPDATED_COUNT counter
test_checksums_updated_count() {
    assert_file_contains "$SOURCE_FILE" "UPDATED_COUNT" \
        "Should track UPDATED_COUNT counter"
}

# Test: FAILED_COUNT counter
test_checksums_failed_count() {
    assert_file_contains "$SOURCE_FILE" "FAILED_COUNT" \
        "Should track FAILED_COUNT counter"
}

# Test: Skips already-valid checksums (placeholder check)
test_checksums_skips_valid() {
    assert_file_contains "$SOURCE_FILE" "placeholder_to_be_added" \
        "Should skip placeholder_to_be_added checksums"
}

# ---------------------------------------------------------------------------
# Static analysis tests: Tool checksum support
# ---------------------------------------------------------------------------

# Test: Defines TOOL_CHECKSUM_REGISTRY_NOARCH
test_checksums_tool_registry_noarch() {
    assert_file_contains "$SOURCE_FILE" "TOOL_CHECKSUM_REGISTRY_NOARCH" \
        "Should define TOOL_CHECKSUM_REGISTRY_NOARCH array"
}

# Test: Defines TOOL_CHECKSUM_REGISTRY_ARCH
test_checksums_tool_registry_arch() {
    assert_file_contains "$SOURCE_FILE" "TOOL_CHECKSUM_REGISTRY_ARCH" \
        "Should define TOOL_CHECKSUM_REGISTRY_ARCH array"
}

# Test: Noarch registry contains entr entry
test_checksums_tool_registry_has_entr() {
    assert_file_contains "$SOURCE_FILE" "entr|ENTR_VERSION" \
        "TOOL_CHECKSUM_REGISTRY_NOARCH should contain entr entry"
}

# Test: Noarch registry contains kotlin-compiler
test_checksums_tool_registry_has_kotlin() {
    assert_file_contains "$SOURCE_FILE" "kotlin-compiler|KOTLIN_VERSION" \
        "TOOL_CHECKSUM_REGISTRY_NOARCH should contain kotlin-compiler entry"
}

# Test: Noarch registry contains spring-boot-cli
test_checksums_tool_registry_has_spring() {
    assert_file_contains "$SOURCE_FILE" "spring-boot-cli|SPRING_VERSION" \
        "TOOL_CHECKSUM_REGISTRY_NOARCH should contain spring-boot-cli entry"
}

# Test: Noarch registry contains jbang
test_checksums_tool_registry_has_jbang() {
    assert_file_contains "$SOURCE_FILE" "jbang|JBANG_VERSION" \
        "TOOL_CHECKSUM_REGISTRY_NOARCH should contain jbang entry"
}

# Test: Arch registry contains direnv
test_checksums_tool_registry_has_direnv() {
    assert_file_contains "$SOURCE_FILE" "direnv|DIRENV_VERSION" \
        "TOOL_CHECKSUM_REGISTRY_ARCH should contain direnv entry"
}

# Test: Arch registry contains biome
test_checksums_tool_registry_has_biome() {
    assert_file_contains "$SOURCE_FILE" "biome|BIOME_VERSION" \
        "TOOL_CHECKSUM_REGISTRY_ARCH should contain biome entry"
}

# Test: Arch registry contains cloudflared
test_checksums_tool_registry_has_cloudflared() {
    assert_file_contains "$SOURCE_FILE" "cloudflared|CLOUDFLARED_VERSION" \
        "TOOL_CHECKSUM_REGISTRY_ARCH should contain cloudflared entry"
}

# Test: Defines extract_tool_version function
test_checksums_defines_extract_tool_version() {
    assert_file_contains "$SOURCE_FILE" "extract_tool_version()" \
        "Should define extract_tool_version function"
}

# Test: Defines update_tool_checksum function
test_checksums_defines_update_tool_checksum() {
    assert_file_contains "$SOURCE_FILE" "update_tool_checksum()" \
        "Should define update_tool_checksum function"
}

# Test: Defines update_tool_checksum_arch function
test_checksums_defines_update_tool_checksum_arch() {
    assert_file_contains "$SOURCE_FILE" "update_tool_checksum_arch()" \
        "Should define update_tool_checksum_arch function"
}

# Test: Tool checksum uses download-and-hash approach
test_checksums_tool_download_and_hash() {
    assert_file_contains "$SOURCE_FILE" "sha256sum" \
        "Should compute sha256 by downloading tool files"
}

# Test: Tool checksum writes to tools.versions path
test_checksums_tool_versions_path() {
    assert_file_contains "$SOURCE_FILE" 'tools.*tool.*versions' \
        "Should write tool checksums to tools.<name>.versions.<version> path"
}

# Test: Arch-dependent tools write per-arch checksums
test_checksums_arch_per_arch_checksums() {
    assert_file_contains "$SOURCE_FILE" 'checksums.*amd64.*sha256' \
        "Should write per-arch checksums for architecture-dependent tools"
}

# Test: URL template uses VERSION placeholder
test_checksums_url_template_placeholder() {
    assert_file_contains "$SOURCE_FILE" "{VERSION}" \
        "URL templates should use {VERSION} placeholder"
}

# ---------------------------------------------------------------------------
# Functional tests
# ---------------------------------------------------------------------------

# Test: Script has valid bash syntax
test_checksums_script_syntax() {
    if bash -n "$SOURCE_FILE" 2>/dev/null; then
        assert_true true "Script has valid bash syntax"
    else
        local errors
        errors=$(bash -n "$SOURCE_FILE" 2>&1 || true)
        echo "Bash syntax errors found:" >&2
        echo "$errors" >&2
        assert_true false "Script contains bash syntax errors"
    fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
run_test_with_setup test_checksums_strict_mode "Script uses set -euo pipefail"
run_test_with_setup test_checksums_defines_update_checksum "Defines update_checksum function"
run_test_with_setup test_checksums_sources_common "Sources bin/lib/common.sh"
run_test_with_setup test_checksums_sources_checksum_fetch "Sources or references checksum-fetch.sh"
run_test_with_setup test_checksums_file_path "CHECKSUMS_FILE references lib/checksums.json"
run_test_with_setup test_checksums_dry_run_variable "DRY_RUN initialized to false"
run_test_with_setup test_checksums_dry_run_flag "--dry-run flag sets DRY_RUN=true"
run_test_with_setup test_checksums_help_flag "--help flag is handled"
run_test_with_setup test_checksums_backup_file "Creates backup file with timestamp pattern"
run_test_with_setup test_checksums_sha256_validation "SHA256 validation uses 64 hex char pattern"
run_test_with_setup test_checksums_processes_nodejs "Processes nodejs language checksums"
run_test_with_setup test_checksums_processes_golang "Processes golang language checksums"
run_test_with_setup test_checksums_processes_ruby "Processes ruby language checksums"
run_test_with_setup test_checksums_updates_metadata_timestamp "Updates metadata.generated timestamp"
run_test_with_setup test_checksums_validates_json "Validates JSON with jq empty"
run_test_with_setup test_checksums_updated_count "Tracks UPDATED_COUNT counter"
run_test_with_setup test_checksums_failed_count "Tracks FAILED_COUNT counter"
run_test_with_setup test_checksums_skips_valid "Skips already-valid checksums"
run_test_with_setup test_checksums_tool_registry_noarch "Defines TOOL_CHECKSUM_REGISTRY_NOARCH array"
run_test_with_setup test_checksums_tool_registry_arch "Defines TOOL_CHECKSUM_REGISTRY_ARCH array"
run_test_with_setup test_checksums_tool_registry_has_entr "Noarch registry contains entr"
run_test_with_setup test_checksums_tool_registry_has_kotlin "Noarch registry contains kotlin-compiler"
run_test_with_setup test_checksums_tool_registry_has_spring "Noarch registry contains spring-boot-cli"
run_test_with_setup test_checksums_tool_registry_has_jbang "Noarch registry contains jbang"
run_test_with_setup test_checksums_tool_registry_has_direnv "Arch registry contains direnv"
run_test_with_setup test_checksums_tool_registry_has_biome "Arch registry contains biome"
run_test_with_setup test_checksums_tool_registry_has_cloudflared "Arch registry contains cloudflared"
run_test_with_setup test_checksums_defines_extract_tool_version "Defines extract_tool_version function"
run_test_with_setup test_checksums_defines_update_tool_checksum "Defines update_tool_checksum function"
run_test_with_setup test_checksums_defines_update_tool_checksum_arch "Defines update_tool_checksum_arch function"
run_test_with_setup test_checksums_tool_download_and_hash "Tool checksums use download-and-hash"
run_test_with_setup test_checksums_tool_versions_path "Tool checksums write to versions path"
run_test_with_setup test_checksums_arch_per_arch_checksums "Arch tools write per-arch checksums"
run_test_with_setup test_checksums_url_template_placeholder "URL templates use VERSION placeholder"
run_test_with_setup test_checksums_script_syntax "Script has valid bash syntax"

# Generate test report
generate_report
