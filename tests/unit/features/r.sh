#!/usr/bin/env bash
# Unit tests for lib/features/r.sh
# Content-based tests that verify the source script structure

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"
init_test_framework
test_suite "r Feature Tests"

# Path to script under test
SOURCE_FILE="$PROJECT_ROOT/lib/features/r.sh"

# ============================================================================
# Script Structure Tests
# ============================================================================

test_script_exists_and_executable() {
    assert_file_exists "$SOURCE_FILE"
    [ -x "$SOURCE_FILE" ] &&
        assert_true 0 "r.sh is executable" ||
        assert_true 1 "r.sh should be executable"
}

test_uses_strict_mode() {
    assert_file_contains "$SOURCE_FILE" "set -euo pipefail" \
        "r.sh uses strict mode"
}

test_sources_feature_header() {
    assert_file_contains "$SOURCE_FILE" "source.*feature-header.sh" \
        "r.sh sources feature-header.sh"
}

test_log_feature_start() {
    assert_file_contains "$SOURCE_FILE" 'log_feature_start "R"' \
        "r.sh logs feature start with correct name"
}

# ============================================================================
# Utility Sourcing Tests
# ============================================================================

test_sources_apt_utils() {
    assert_file_contains "$SOURCE_FILE" "source.*apt-utils.sh" \
        "r.sh sources apt-utils.sh"
}

test_sources_retry_utils() {
    assert_file_contains "$SOURCE_FILE" "source.*retry-utils.sh" \
        "r.sh sources retry-utils.sh"
}

test_sources_version_validation() {
    assert_file_contains "$SOURCE_FILE" "source.*version-validation.sh" \
        "r.sh sources version-validation.sh"
}

test_sources_cache_utils() {
    assert_file_contains "$SOURCE_FILE" "source.*cache-utils.sh" \
        "r.sh sources cache-utils.sh"
}

# ============================================================================
# Version & Repository Tests
# ============================================================================

test_version_validation() {
    assert_file_contains "$SOURCE_FILE" "validate_r_version" \
        "r.sh validates R version format"
}

test_cran_repository_setup() {
    assert_file_contains "$SOURCE_FILE" "cloud.r-project.org" \
        "r.sh configures CRAN repository"
}

test_apt_packages() {
    assert_file_contains "$SOURCE_FILE" "r-base" \
        "r.sh installs r-base package"
    assert_file_contains "$SOURCE_FILE" "r-base-dev" \
        "r.sh installs r-base-dev package"
}

# ============================================================================
# Configuration Tests
# ============================================================================

test_cache_directory() {
    assert_file_contains "$SOURCE_FILE" "/cache/r" \
        "r.sh configures /cache/r directory"
    assert_file_contains "$SOURCE_FILE" "R_LIBS_USER" \
        "r.sh sets R_LIBS_USER"
}

test_bashrc_config() {
    assert_file_contains "$SOURCE_FILE" "40-r.sh" \
        "r.sh creates 40-r.sh bashrc config"
}

test_renviron_site_configuration() {
    assert_file_contains "$SOURCE_FILE" "Renviron.site" \
        "r.sh creates Renviron.site configuration"
}

test_rprofile_site_configuration() {
    assert_file_contains "$SOURCE_FILE" "Rprofile.site" \
        "r.sh creates Rprofile.site configuration"
}

run_test test_script_exists_and_executable "Script exists and is executable"
run_test test_uses_strict_mode "Uses set -euo pipefail"
run_test test_sources_feature_header "Sources feature-header.sh"
run_test test_log_feature_start "Logs feature start with correct name"
run_test test_sources_apt_utils "Sources apt-utils.sh"
run_test test_sources_retry_utils "Sources retry-utils.sh"
run_test test_sources_version_validation "Sources version-validation.sh"
run_test test_sources_cache_utils "Sources cache-utils.sh"
run_test test_version_validation "Version validation (validate_r_version)"
run_test test_cran_repository_setup "CRAN repository setup"
run_test test_apt_packages "APT packages (r-base, r-base-dev)"
run_test test_cache_directory "Cache directory (/cache/r, R_LIBS_USER)"
run_test test_bashrc_config "Bashrc config (40-r.sh)"
run_test test_renviron_site_configuration "Renviron.site configuration"
run_test test_rprofile_site_configuration "Rprofile.site configuration"

generate_report
