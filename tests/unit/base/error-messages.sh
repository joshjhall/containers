#!/usr/bin/env bash
# Unit tests for lib/base/error-messages.sh
# Tests standardized error message functions for consistent user experience

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Error Messages Tests"

# Source file under test
SOURCE_FILE="$PROJECT_ROOT/lib/base/error-messages.sh"

# Setup function - runs before each test
setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$RESULTS_DIR/test-error-messages-$unique_id"
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

# Helper: run a subshell that sources the file with a mock log_error
# The mock log_error echoes to stdout so we can capture output
_run_error_subshell() {
    bash -c "
        source '$SOURCE_FILE' >/dev/null 2>&1
        log_error() { echo \"ERROR: \$*\"; }
        export -f log_error
        $1
    " 2>/dev/null
}

# ============================================================================
# Static Analysis Tests
# ============================================================================

test_strict_mode() {
    assert_file_contains "$SOURCE_FILE" "set -euo pipefail" \
        "Script uses strict mode"
}

test_defines_error_package_not_found() {
    assert_file_contains "$SOURCE_FILE" "error_package_not_found()" \
        "Script defines error_package_not_found function"
}

test_defines_error_dependency_failed() {
    assert_file_contains "$SOURCE_FILE" "error_dependency_failed()" \
        "Script defines error_dependency_failed function"
}

test_defines_error_command_not_found() {
    assert_file_contains "$SOURCE_FILE" "error_command_not_found()" \
        "Script defines error_command_not_found function"
}

test_defines_error_download_failed() {
    assert_file_contains "$SOURCE_FILE" "error_download_failed()" \
        "Script defines error_download_failed function"
}

test_defines_error_connection_timeout() {
    assert_file_contains "$SOURCE_FILE" "error_connection_timeout()" \
        "Script defines error_connection_timeout function"
}

test_defines_error_certificate_error() {
    assert_file_contains "$SOURCE_FILE" "error_certificate_error()" \
        "Script defines error_certificate_error function"
}

test_defines_error_checksum_mismatch() {
    assert_file_contains "$SOURCE_FILE" "error_checksum_mismatch()" \
        "Script defines error_checksum_mismatch function"
}

test_defines_error_gpg_verification_failed() {
    assert_file_contains "$SOURCE_FILE" "error_gpg_verification_failed()" \
        "Script defines error_gpg_verification_failed function"
}

test_defines_error_gpg_key_not_found() {
    assert_file_contains "$SOURCE_FILE" "error_gpg_key_not_found()" \
        "Script defines error_gpg_key_not_found function"
}

test_defines_error_sigstore_verification_failed() {
    assert_file_contains "$SOURCE_FILE" "error_sigstore_verification_failed()" \
        "Script defines error_sigstore_verification_failed function"
}

test_defines_error_version_not_found() {
    assert_file_contains "$SOURCE_FILE" "error_version_not_found()" \
        "Script defines error_version_not_found function"
}

test_defines_error_unsupported_version() {
    assert_file_contains "$SOURCE_FILE" "error_unsupported_version()" \
        "Script defines error_unsupported_version function"
}

test_defines_error_architecture_not_supported() {
    assert_file_contains "$SOURCE_FILE" "error_architecture_not_supported()" \
        "Script defines error_architecture_not_supported function"
}

test_defines_error_os_not_supported() {
    assert_file_contains "$SOURCE_FILE" "error_os_not_supported()" \
        "Script defines error_os_not_supported function"
}

test_defines_error_file_not_found() {
    assert_file_contains "$SOURCE_FILE" "error_file_not_found()" \
        "Script defines error_file_not_found function"
}

test_defines_error_directory_not_found() {
    assert_file_contains "$SOURCE_FILE" "error_directory_not_found()" \
        "Script defines error_directory_not_found function"
}

test_defines_error_permission_denied() {
    assert_file_contains "$SOURCE_FILE" "error_permission_denied()" \
        "Script defines error_permission_denied function"
}

test_defines_error_disk_space() {
    assert_file_contains "$SOURCE_FILE" "error_disk_space()" \
        "Script defines error_disk_space function"
}

test_defines_error_invalid_config() {
    assert_file_contains "$SOURCE_FILE" "error_invalid_config()" \
        "Script defines error_invalid_config function"
}

test_defines_error_missing_env_var() {
    assert_file_contains "$SOURCE_FILE" "error_missing_env_var()" \
        "Script defines error_missing_env_var function"
}

test_defines_error_invalid_env_var() {
    assert_file_contains "$SOURCE_FILE" "error_invalid_env_var()" \
        "Script defines error_invalid_env_var function"
}

test_defines_error_build_failed() {
    assert_file_contains "$SOURCE_FILE" "error_build_failed()" \
        "Script defines error_build_failed function"
}

test_defines_error_installation_failed() {
    assert_file_contains "$SOURCE_FILE" "error_installation_failed()" \
        "Script defines error_installation_failed function"
}

test_defines_error_verification_failed() {
    assert_file_contains "$SOURCE_FILE" "error_verification_failed()" \
        "Script defines error_verification_failed function"
}

# ============================================================================
# Static Analysis Tests - Exports
# ============================================================================

test_exports_all_functions() {
    assert_file_contains "$SOURCE_FILE" "export -f error_package_not_found" \
        "error_package_not_found is exported"
    assert_file_contains "$SOURCE_FILE" "export -f error_dependency_failed" \
        "error_dependency_failed is exported"
    assert_file_contains "$SOURCE_FILE" "export -f error_command_not_found" \
        "error_command_not_found is exported"
    assert_file_contains "$SOURCE_FILE" "export -f error_download_failed" \
        "error_download_failed is exported"
    assert_file_contains "$SOURCE_FILE" "export -f error_connection_timeout" \
        "error_connection_timeout is exported"
    assert_file_contains "$SOURCE_FILE" "export -f error_certificate_error" \
        "error_certificate_error is exported"
    assert_file_contains "$SOURCE_FILE" "export -f error_checksum_mismatch" \
        "error_checksum_mismatch is exported"
    assert_file_contains "$SOURCE_FILE" "export -f error_gpg_verification_failed" \
        "error_gpg_verification_failed is exported"
    assert_file_contains "$SOURCE_FILE" "export -f error_gpg_key_not_found" \
        "error_gpg_key_not_found is exported"
    assert_file_contains "$SOURCE_FILE" "export -f error_sigstore_verification_failed" \
        "error_sigstore_verification_failed is exported"
    assert_file_contains "$SOURCE_FILE" "export -f error_version_not_found" \
        "error_version_not_found is exported"
    assert_file_contains "$SOURCE_FILE" "export -f error_unsupported_version" \
        "error_unsupported_version is exported"
    assert_file_contains "$SOURCE_FILE" "export -f error_architecture_not_supported" \
        "error_architecture_not_supported is exported"
    assert_file_contains "$SOURCE_FILE" "export -f error_os_not_supported" \
        "error_os_not_supported is exported"
    assert_file_contains "$SOURCE_FILE" "export -f error_file_not_found" \
        "error_file_not_found is exported"
    assert_file_contains "$SOURCE_FILE" "export -f error_directory_not_found" \
        "error_directory_not_found is exported"
    assert_file_contains "$SOURCE_FILE" "export -f error_permission_denied" \
        "error_permission_denied is exported"
    assert_file_contains "$SOURCE_FILE" "export -f error_disk_space" \
        "error_disk_space is exported"
    assert_file_contains "$SOURCE_FILE" "export -f error_invalid_config" \
        "error_invalid_config is exported"
    assert_file_contains "$SOURCE_FILE" "export -f error_missing_env_var" \
        "error_missing_env_var is exported"
    assert_file_contains "$SOURCE_FILE" "export -f error_invalid_env_var" \
        "error_invalid_env_var is exported"
    assert_file_contains "$SOURCE_FILE" "export -f error_build_failed" \
        "error_build_failed is exported"
    assert_file_contains "$SOURCE_FILE" "export -f error_installation_failed" \
        "error_installation_failed is exported"
    assert_file_contains "$SOURCE_FILE" "export -f error_verification_failed" \
        "error_verification_failed is exported"
}

# ============================================================================
# Functional Tests - Error Output Validation
# ============================================================================

test_checksum_mismatch_output() {
    local output
    output=$(_run_error_subshell "error_checksum_mismatch 'python-3.12.7.tar.gz' 'abc123' 'def456'")

    assert_contains "$output" "Expected: abc123" \
        "error_checksum_mismatch should include expected value"
    assert_contains "$output" "Got:      def456" \
        "error_checksum_mismatch should include actual value"
    assert_contains "$output" "python-3.12.7.tar.gz" \
        "error_checksum_mismatch should include filename"
}

test_download_failed_output() {
    local output
    output=$(_run_error_subshell "error_download_failed 'https://example.com/file.tar.gz' '404'")

    assert_contains "$output" "https://example.com/file.tar.gz" \
        "error_download_failed should include URL"
    assert_contains "$output" "HTTP status code: 404" \
        "error_download_failed should include HTTP status"
}

test_missing_env_var_output() {
    local output
    output=$(_run_error_subshell "error_missing_env_var 'PYTHON_VERSION' 'Python version to install'")

    assert_contains "$output" "PYTHON_VERSION" \
        "error_missing_env_var should include variable name"
    assert_contains "$output" "Description: Python version to install" \
        "error_missing_env_var should include description"
}

test_command_not_found_with_hint() {
    local output
    output=$(_run_error_subshell "error_command_not_found 'curl' 'apt-get install -y curl'")

    assert_contains "$output" "curl" \
        "error_command_not_found should include command name"
    assert_contains "$output" "Install with: apt-get install -y curl" \
        "error_command_not_found should include install hint"
}

test_command_not_found_without_hint() {
    local output
    output=$(_run_error_subshell "error_command_not_found 'mycommand'")

    assert_contains "$output" "mycommand" \
        "error_command_not_found should include command name"
    assert_not_contains "$output" "Install with:" \
        "error_command_not_found should not include install hint when not provided"
}

test_connection_timeout_output() {
    local output
    output=$(_run_error_subshell "error_connection_timeout 'https://slow-server.com' '60'")

    assert_contains "$output" "https://slow-server.com" \
        "error_connection_timeout should include URL"
    assert_contains "$output" "60s" \
        "error_connection_timeout should include timeout value"
}

test_version_not_found_output() {
    local output
    output=$(_run_error_subshell "error_version_not_found 'Python' '3.99.0'")

    assert_contains "$output" "3.99.0" \
        "error_version_not_found should include version"
    assert_contains "$output" "Python" \
        "error_version_not_found should include tool name"
}

test_unsupported_version_with_min_version() {
    local output
    output=$(_run_error_subshell "error_unsupported_version 'Node' '10.0.0' '16.0.0'")

    assert_contains "$output" "10.0.0" \
        "error_unsupported_version should include requested version"
    assert_contains "$output" "Minimum required version: 16.0.0" \
        "error_unsupported_version should include minimum version"
}

test_permission_denied_output() {
    local output
    output=$(_run_error_subshell "error_permission_denied '/etc/shadow' 'read'")

    assert_contains "$output" "/etc/shadow" \
        "error_permission_denied should include path"
    assert_contains "$output" "cannot read" \
        "error_permission_denied should include operation"
}

# ============================================================================
# Run all tests
# ============================================================================

# Static analysis - strict mode
run_test_with_setup test_strict_mode "Script uses strict mode"

# Static analysis - function definitions
run_test_with_setup test_defines_error_package_not_found "Defines error_package_not_found function"
run_test_with_setup test_defines_error_dependency_failed "Defines error_dependency_failed function"
run_test_with_setup test_defines_error_command_not_found "Defines error_command_not_found function"
run_test_with_setup test_defines_error_download_failed "Defines error_download_failed function"
run_test_with_setup test_defines_error_connection_timeout "Defines error_connection_timeout function"
run_test_with_setup test_defines_error_certificate_error "Defines error_certificate_error function"
run_test_with_setup test_defines_error_checksum_mismatch "Defines error_checksum_mismatch function"
run_test_with_setup test_defines_error_gpg_verification_failed "Defines error_gpg_verification_failed function"
run_test_with_setup test_defines_error_gpg_key_not_found "Defines error_gpg_key_not_found function"
run_test_with_setup test_defines_error_sigstore_verification_failed "Defines error_sigstore_verification_failed function"
run_test_with_setup test_defines_error_version_not_found "Defines error_version_not_found function"
run_test_with_setup test_defines_error_unsupported_version "Defines error_unsupported_version function"
run_test_with_setup test_defines_error_architecture_not_supported "Defines error_architecture_not_supported function"
run_test_with_setup test_defines_error_os_not_supported "Defines error_os_not_supported function"
run_test_with_setup test_defines_error_file_not_found "Defines error_file_not_found function"
run_test_with_setup test_defines_error_directory_not_found "Defines error_directory_not_found function"
run_test_with_setup test_defines_error_permission_denied "Defines error_permission_denied function"
run_test_with_setup test_defines_error_disk_space "Defines error_disk_space function"
run_test_with_setup test_defines_error_invalid_config "Defines error_invalid_config function"
run_test_with_setup test_defines_error_missing_env_var "Defines error_missing_env_var function"
run_test_with_setup test_defines_error_invalid_env_var "Defines error_invalid_env_var function"
run_test_with_setup test_defines_error_build_failed "Defines error_build_failed function"
run_test_with_setup test_defines_error_installation_failed "Defines error_installation_failed function"
run_test_with_setup test_defines_error_verification_failed "Defines error_verification_failed function"

# Static analysis - exports
run_test_with_setup test_exports_all_functions "All error functions are exported"

# Functional tests - error output validation
run_test_with_setup test_checksum_mismatch_output "error_checksum_mismatch includes expected and actual values"
run_test_with_setup test_download_failed_output "error_download_failed includes URL and HTTP status"
run_test_with_setup test_missing_env_var_output "error_missing_env_var includes variable name and description"
run_test_with_setup test_command_not_found_with_hint "error_command_not_found includes install hint when provided"
run_test_with_setup test_command_not_found_without_hint "error_command_not_found omits install hint when not provided"
run_test_with_setup test_connection_timeout_output "error_connection_timeout includes URL and timeout"
run_test_with_setup test_version_not_found_output "error_version_not_found includes tool and version"
run_test_with_setup test_unsupported_version_with_min_version "error_unsupported_version includes minimum version"
run_test_with_setup test_permission_denied_output "error_permission_denied includes path and operation"

# Generate test report
generate_report
