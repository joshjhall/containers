#!/usr/bin/env bash
# Unit tests for lib/features/mojo-dev.sh
# Content-based tests that verify the source script structure

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"
init_test_framework
test_suite "mojo-dev Feature Tests"

# Path to script under test
SOURCE_FILE="$PROJECT_ROOT/lib/features/mojo-dev.sh"

# ============================================================================
# Script Structure Tests
# ============================================================================

test_script_exists_and_executable() {
    assert_file_exists "$SOURCE_FILE"
    [ -x "$SOURCE_FILE" ] \
        && assert_true 0 "mojo-dev.sh is executable" \
        || assert_true 1 "mojo-dev.sh should be executable"
}

test_uses_strict_mode() {
    assert_file_contains "$SOURCE_FILE" "set -euo pipefail" \
        "mojo-dev.sh uses strict mode"
}

test_sources_feature_header_bootstrap() {
    assert_file_contains "$SOURCE_FILE" "source.*feature-header-bootstrap.sh" \
        "mojo-dev.sh sources feature-header-bootstrap.sh"
}

test_log_feature_start() {
    assert_file_contains "$SOURCE_FILE" 'log_feature_start "Mojo Development Tools"' \
        "mojo-dev.sh logs feature start with correct name"
}

test_sources_apt_utils() {
    assert_file_contains "$SOURCE_FILE" "source.*apt-utils.sh" \
        "mojo-dev.sh sources apt-utils.sh"
}

# ============================================================================
# Prerequisites Tests
# ============================================================================

test_prerequisite_check_for_mojo() {
    assert_file_contains "$SOURCE_FILE" "/usr/local/bin/mojo" \
        "mojo-dev.sh checks for mojo binary"
    assert_file_contains "$SOURCE_FILE" "INCLUDE_MOJO" \
        "mojo-dev.sh references INCLUDE_MOJO requirement"
}

# ============================================================================
# Installation Tests
# ============================================================================

test_installs_lldb_debugger() {
    assert_file_contains "$SOURCE_FILE" "lldb" \
        "mojo-dev.sh installs lldb debugger"
}

test_python_interop_packages() {
    assert_file_contains "$SOURCE_FILE" "numpy" \
        "mojo-dev.sh installs numpy for Python interop"
    assert_file_contains "$SOURCE_FILE" "matplotlib" \
        "mojo-dev.sh installs matplotlib for Python interop"
}

# ============================================================================
# Configuration Tests
# ============================================================================

test_bashrc_config() {
    assert_file_contains "$SOURCE_FILE" "65-mojo-dev.sh" \
        "mojo-dev.sh creates 65-mojo-dev.sh bashrc config"
}

run_test test_script_exists_and_executable "Script exists and is executable"
run_test test_uses_strict_mode "Uses set -euo pipefail"
run_test test_sources_feature_header_bootstrap "Sources feature-header-bootstrap.sh"
run_test test_log_feature_start "Logs feature start with correct name"
run_test test_sources_apt_utils "Sources apt-utils.sh"
run_test test_prerequisite_check_for_mojo "Prerequisite check for mojo binary"
run_test test_installs_lldb_debugger "Installs lldb debugger"
run_test test_python_interop_packages "Python interop packages (numpy, matplotlib)"
run_test test_bashrc_config "Bashrc config (65-mojo-dev.sh)"

generate_report
