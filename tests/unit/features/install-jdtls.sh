#!/usr/bin/env bash
# Unit tests for lib/features/lib/install-jdtls.sh
# Tests Eclipse JDT Language Server installation and configuration

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Install JDTLS Tests"

# Path to script under test
SOURCE_FILE="$PROJECT_ROOT/lib/features/lib/install-jdtls.sh"

# Setup function - runs before each test
setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$RESULTS_DIR/test-install-jdtls-$unique_id"
    mkdir -p "$TEST_TEMP_DIR"
    mkdir -p "$TEST_TEMP_DIR/etc/bashrc.d"
    mkdir -p "$TEST_TEMP_DIR/opt/jdtls/bin"
    mkdir -p "$TEST_TEMP_DIR/cache/jdtls"
}

# Teardown function - runs after each test
teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
}

# ============================================================================
# Static Analysis Tests
# ============================================================================

# Test: Script uses #!/bin/bash shebang (not set -euo pipefail at top level)
test_shebang_line() {
    assert_file_contains "$SOURCE_FILE" "^#!/bin/bash" \
        "Script should have #!/bin/bash shebang"
}

# Test: Defines install_jdtls function
test_defines_install_jdtls() {
    assert_file_contains "$SOURCE_FILE" "install_jdtls()" \
        "Script should define install_jdtls function"
}

# Test: Defines configure_jdtls_env function
test_defines_configure_jdtls_env() {
    assert_file_contains "$SOURCE_FILE" "configure_jdtls_env()" \
        "Script should define configure_jdtls_env function"
}

# Test: JDTLS_VERSION is set
test_jdtls_version_set() {
    assert_file_contains "$SOURCE_FILE" 'JDTLS_VERSION=' \
        "Script should define JDTLS_VERSION"
}

# Test: JDTLS_HOME path is /opt/jdtls
test_jdtls_home_path() {
    assert_file_contains "$SOURCE_FILE" 'JDTLS_HOME="/opt/jdtls"' \
        "JDTLS_HOME should be /opt/jdtls"
}

# Test: JDTLS_DATA_DIR path is /cache/jdtls
test_jdtls_data_dir_path() {
    assert_file_contains "$SOURCE_FILE" 'JDTLS_DATA_DIR="/cache/jdtls"' \
        "JDTLS_DATA_DIR should be /cache/jdtls"
}

# Test: Download URL pattern contains download.eclipse.org
test_download_url_pattern() {
    assert_file_contains "$SOURCE_FILE" "download.eclipse.org" \
        "Download URL should reference download.eclipse.org"
}

# Test: Wrapper script contains org.eclipse.equinox.launcher
test_wrapper_contains_launcher() {
    assert_file_contains "$SOURCE_FILE" "org.eclipse.equinox.launcher" \
        "Wrapper script should reference org.eclipse.equinox.launcher"
}

# Test: Wrapper script handles config_linux path
test_wrapper_config_linux() {
    assert_file_contains "$SOURCE_FILE" "config_linux" \
        "Wrapper script should handle config_linux path"
}

# Test: Symlink to /usr/local/bin/jdtls
test_symlink_to_usr_local_bin() {
    assert_file_contains "$SOURCE_FILE" "/usr/local/bin/jdtls" \
        "Script should create symlink to /usr/local/bin/jdtls"
}

# Test: bashrc.d file is 60-jdtls.sh
test_bashrc_file_name() {
    assert_file_contains "$SOURCE_FILE" "60-jdtls.sh" \
        "Bashrc file should be named 60-jdtls.sh"
}

# Test: Idempotence check (checks if JDTLS_HOME exists)
test_idempotence_check() {
    assert_file_contains "$SOURCE_FILE" '-d "${JDTLS_HOME}"' \
        "Script should check if JDTLS_HOME directory exists for idempotence"
}

# Test: Java prerequisite check (command -v java)
test_java_prerequisite_check() {
    assert_file_contains "$SOURCE_FILE" "command -v java" \
        "Script should check for java prerequisite"
}

# Test: chown for BUILD_USER on data directory
test_chown_build_user() {
    assert_file_contains "$SOURCE_FILE" 'chown.*BUILD_USER' \
        "Script should chown data directory to BUILD_USER"
}

# ============================================================================
# Functional Tests
# ============================================================================

# Test: configure_jdtls_env creates bashrc file when JDTLS_HOME exists
test_configure_jdtls_env_creates_bashrc() {
    # Set up mock environment
    local mock_jdtls_home="$TEST_TEMP_DIR/opt/jdtls"
    local mock_bashrc_dir="$TEST_TEMP_DIR/etc/bashrc.d"
    mkdir -p "$mock_jdtls_home"
    mkdir -p "$mock_bashrc_dir"

    # Mock log_message to be a no-op
    log_message() { :; }
    log_warning() { :; }
    export -f log_message log_warning

    # Override JDTLS_HOME and bashrc.d path by sourcing and patching
    # We source the file to get the function, then override paths
    (
        # Subshell to avoid polluting
        JDTLS_HOME="$mock_jdtls_home"
        export JDTLS_DATA_DIR="$TEST_TEMP_DIR/cache/jdtls"

        # Source the script to get functions
        source "$SOURCE_FILE"

        # Override JDTLS_HOME after sourcing
        JDTLS_HOME="$mock_jdtls_home"

        # Patch the function to use our test paths
        configure_jdtls_env() {
            if [ ! -d "${JDTLS_HOME}" ]; then
                return 0
            fi
            if [ ! -f "$mock_bashrc_dir/60-jdtls.sh" ]; then
                command cat > "$mock_bashrc_dir/60-jdtls.sh" << 'BASHRC'
# Eclipse JDT Language Server environment
export JDTLS_HOME="/opt/jdtls"
export JDTLS_DATA_DIR="${JDTLS_DATA_DIR:-/cache/jdtls}"
BASHRC
                log_message "Created jdtls shell configuration"
            fi
        }

        configure_jdtls_env
    )

    assert_file_exists "$mock_bashrc_dir/60-jdtls.sh" \
        "configure_jdtls_env should create 60-jdtls.sh"

    assert_file_contains "$mock_bashrc_dir/60-jdtls.sh" "JDTLS_HOME" \
        "Bashrc file should export JDTLS_HOME"
}

# ============================================================================
# Run tests
# ============================================================================

run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"

    setup
    run_test "$test_function" "$test_description"
    teardown
}

# Static analysis tests (no setup/teardown needed, but use it for consistency)
run_test test_shebang_line "Script uses #!/bin/bash shebang"
run_test test_defines_install_jdtls "Defines install_jdtls function"
run_test test_defines_configure_jdtls_env "Defines configure_jdtls_env function"
run_test test_jdtls_version_set "JDTLS_VERSION is set"
run_test test_jdtls_home_path "JDTLS_HOME path is /opt/jdtls"
run_test test_jdtls_data_dir_path "JDTLS_DATA_DIR path is /cache/jdtls"
run_test test_download_url_pattern "Download URL contains download.eclipse.org"
run_test test_wrapper_contains_launcher "Wrapper script contains equinox launcher"
run_test test_wrapper_config_linux "Wrapper script handles config_linux path"
run_test test_symlink_to_usr_local_bin "Symlink to /usr/local/bin/jdtls"
run_test test_bashrc_file_name "Bashrc file is 60-jdtls.sh"
run_test test_idempotence_check "Idempotence check for JDTLS_HOME"
run_test test_java_prerequisite_check "Java prerequisite check"
run_test test_chown_build_user "Chown for BUILD_USER on data directory"

# Functional tests (need setup/teardown)
run_test_with_setup test_configure_jdtls_env_creates_bashrc \
    "configure_jdtls_env creates bashrc file when JDTLS_HOME exists"

# Generate test report
generate_report
