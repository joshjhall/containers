#!/usr/bin/env bash
# Unit tests for lib/features/r-dev.sh
# Content-based tests that verify the source script structure

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"
init_test_framework
test_suite "r-dev Feature Tests"

# Path to script under test
SOURCE_FILE="$PROJECT_ROOT/lib/features/r-dev.sh"

# ============================================================================
# Script Structure Tests
# ============================================================================

test_script_exists_and_executable() {
    assert_file_exists "$SOURCE_FILE"
    [ -x "$SOURCE_FILE" ] &&
        assert_true 0 "r-dev.sh is executable" ||
        assert_true 1 "r-dev.sh should be executable"
}

test_uses_strict_mode() {
    assert_file_contains "$SOURCE_FILE" "set -euo pipefail" \
        "r-dev.sh uses strict mode"
}

test_sources_feature_header() {
    assert_file_contains "$SOURCE_FILE" "source.*feature-header.sh" \
        "r-dev.sh sources feature-header.sh"
}

test_log_feature_start() {
    assert_file_contains "$SOURCE_FILE" 'log_feature_start "R Development Tools"' \
        "r-dev.sh logs feature start with correct name"
}

test_sources_apt_utils() {
    assert_file_contains "$SOURCE_FILE" "source.*apt-utils.sh" \
        "r-dev.sh sources apt-utils.sh"
}

# ============================================================================
# Prerequisites Tests
# ============================================================================

test_prerequisite_check_for_r() {
    assert_file_contains "$SOURCE_FILE" "/usr/local/bin/R" \
        "r-dev.sh checks for R binary"
    assert_file_contains "$SOURCE_FILE" "INCLUDE_R" \
        "r-dev.sh references INCLUDE_R requirement"
}

# ============================================================================
# Dev Packages Tests
# ============================================================================

test_dev_packages() {
    assert_file_contains "$SOURCE_FILE" "devtools" \
        "r-dev.sh installs devtools"
    assert_file_contains "$SOURCE_FILE" "testthat" \
        "r-dev.sh installs testthat"
}

test_language_server() {
    assert_file_contains "$SOURCE_FILE" "languageserver" \
        "r-dev.sh installs R language server"
}

# ============================================================================
# Configuration Tests
# ============================================================================

test_bashrc_config() {
    assert_file_contains "$SOURCE_FILE" "45-r-dev.sh" \
        "r-dev.sh creates 45-r-dev.sh bashrc config"
}

run_test test_script_exists_and_executable "Script exists and is executable"
run_test test_uses_strict_mode "Uses set -euo pipefail"
run_test test_sources_feature_header "Sources feature-header.sh"
run_test test_log_feature_start "Logs feature start with correct name"
run_test test_sources_apt_utils "Sources apt-utils.sh"
run_test test_prerequisite_check_for_r "Prerequisite check for R binary"
run_test test_dev_packages "Dev packages (devtools, testthat)"
run_test test_language_server "Language server (languageserver)"
run_test test_bashrc_config "Bashrc config (45-r-dev.sh)"

generate_report
