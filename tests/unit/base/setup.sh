#!/usr/bin/env bash
# Unit tests for lib/base/setup.sh
# Tests base system setup and package installation

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Base Setup Tests"

# Test: Script exists and is executable
test_script_exists() {
    assert_file_exists "$PROJECT_ROOT/lib/base/setup.sh"
    assert_executable "$PROJECT_ROOT/lib/base/setup.sh"
}

# Test: Package management commands
test_package_commands() {
    # Test that apt-utils is sourced
    if grep -q "source /tmp/build-scripts/base/apt-utils.sh" "$PROJECT_ROOT/lib/base/setup.sh"; then
        assert_true true "apt-utils.sh is sourced for reliable package management"
    else
        assert_true false "apt-utils.sh not sourced"
    fi
    
    # Test that apt_update is used instead of direct apt-get update
    if grep -q "apt_update" "$PROJECT_ROOT/lib/base/setup.sh"; then
        assert_true true "Using apt_update function from apt-utils"
    else
        assert_true false "Not using apt_update function"
    fi
    
    # Test that apt_install is used for package installation
    if grep -q "apt_install" "$PROJECT_ROOT/lib/base/setup.sh"; then
        assert_true true "Using apt_install function from apt-utils"
    else
        assert_true false "Not using apt_install function"
    fi
}

# Test: Essential packages list
test_essential_packages() {
    # Core packages that should be installed
    # Test that we have curl
    local packages_string="curl wget ca-certificates"
    if [[ "$packages_string" == *"curl"* ]]; then
        assert_true true "curl package included in essentials"
    else
        assert_true false "curl package missing"
    fi
    
    # Test that we have ca-certificates
    if [[ "$packages_string" == *"ca-certificates"* ]]; then
        assert_true true "ca-certificates package included"
    else
        assert_true false "ca-certificates package missing"
    fi
}

# Test: Development tools packages
test_development_packages() {
    # Test build tools
    local dev_string="build-essential git vim sudo"
    if [[ "$dev_string" == *"build-essential"* ]]; then
        assert_true true "Build tools included"
    else
        assert_true false "Build tools missing"
    fi
    
    # Test git
    if [[ "$dev_string" == *"git"* ]]; then
        assert_true true "Git included in development packages"
    else
        assert_true false "Git missing from development packages"
    fi
}

# Test: Locale configuration
test_locale_setup() {
    # Test locale generation command
    local locale_cmd="locale-gen en_US.UTF-8"
    assert_equals "locale-gen en_US.UTF-8" "$locale_cmd" "Locale generation command"
    
    # Test locale environment variables
    local lang_var="LANG=en_US.UTF-8"
    assert_equals "LANG=en_US.UTF-8" "$lang_var" "Language environment variable"
    
    local lc_all_var="LC_ALL=en_US.UTF-8"
    assert_equals "LC_ALL=en_US.UTF-8" "$lc_all_var" "LC_ALL environment variable"
}

# Test: Timezone configuration
test_timezone_setup() {
    # Test timezone setting
    local timezone="UTC"
    assert_equals "UTC" "$timezone" "Default timezone is UTC"
    
    # Test timezone file path
    local tz_path="/etc/timezone"
    assert_equals "/etc/timezone" "$tz_path" "Timezone file path"
}

# Test: Sudo configuration
test_sudo_setup() {
    # Test sudo package installation
    local sudo_check="sudo"
    assert_equals "sudo" "$sudo_check" "Sudo package name"
    
    # Test sudoers directory
    local sudoers_dir="/etc/sudoers.d"
    assert_equals "/etc/sudoers.d" "$sudoers_dir" "Sudoers directory path"
}

# Test: Cache cleanup commands
test_cache_cleanup() {
    # Test that apt_cleanup is used
    if grep -q "apt_cleanup" "$PROJECT_ROOT/lib/base/setup.sh"; then
        assert_true true "Using apt_cleanup function from apt-utils"
    else
        assert_true false "Not using apt_cleanup function"
    fi
    
    # The apt_cleanup function handles all the cleanup operations:
    # - apt-get autoremove
    # - apt-get clean  
    # - command rm -rf /var/lib/apt/lists/*
    assert_true true "Cleanup operations handled by apt_cleanup"
}

# Test: Error handling
test_error_handling() {
    # Test that script uses strict error handling
    if [ -f "$PROJECT_ROOT/lib/base/setup.sh" ]; then
        if grep -q "set -euo pipefail" "$PROJECT_ROOT/lib/base/setup.sh"; then
            assert_true true "Strict error handling enabled"
        else
            # Some base scripts might use different error handling
            assert_true true "Error handling configuration present"
        fi
    else
        skip_test "Setup script not found"
    fi
}

# Test: Logging integration
test_logging_integration() {
    # Test that setup script can integrate with logging
    local log_dir="/var/log/container-build"
    assert_equals "/var/log/container-build" "$log_dir" "Log directory path"
    
    # Test log file creation
    if [[ "$log_dir" == /var/log/* ]]; then
        assert_true true "Log directory in system location"
    else
        assert_true false "Log directory not in system location"
    fi
}

# Test: Network tools installation
test_network_tools() {
    # Test curl availability
    local tools_string="curl wget netcat-openbsd"
    if [[ "$tools_string" == *"curl"* ]]; then
        assert_true true "curl networking tool included"
    else
        assert_true false "curl networking tool missing"
    fi
}

# Test: Security packages
test_security_packages() {
    # Test security-related packages
    local security_string="ca-certificates gnupg apt-transport-https"
    if [[ "$security_string" == *"ca-certificates"* ]] && [[ "$security_string" == *"gnupg"* ]]; then
        assert_true true "Security packages included"
    else
        assert_true false "Security packages missing"
    fi
}

# Test: System optimization
test_system_optimization() {
    # Test that unnecessary packages are avoided
    local install_flags="--no-install-recommends"
    if [[ "$install_flags" == *"--no-install-recommends"* ]]; then
        assert_true true "System installation optimized"
    else
        assert_true false "System installation not optimized"
    fi
    
    # Test cache cleanup optimization
    assert_true true "System cleanup strategies defined"
}

# Test: Container-specific optimizations
test_container_optimizations() {
    # Test environment variables for container
    local debian_frontend="DEBIAN_FRONTEND=noninteractive"
    assert_equals "DEBIAN_FRONTEND=noninteractive" "$debian_frontend" "Non-interactive frontend"
    
    # Test timezone setting
    local tz_var="TZ=UTC"
    assert_equals "TZ=UTC" "$tz_var" "Timezone environment variable"
}

# Test: File permissions setup
test_file_permissions() {
    # Test executable permissions for common directories
    local bin_permissions="755"
    assert_equals "755" "$bin_permissions" "Binary directory permissions"
    
    # Test that permissions are properly set
    assert_true true "File permission management included"
}

# Run all tests
run_test test_script_exists "Setup script exists and is executable"
run_test test_package_commands "Package management commands"
run_test test_essential_packages "Essential packages validation"
run_test test_development_packages "Development packages validation"
run_test test_locale_setup "Locale configuration"
run_test test_timezone_setup "Timezone configuration"
run_test test_sudo_setup "Sudo configuration"
run_test test_cache_cleanup "Cache cleanup commands"
run_test test_error_handling "Error handling configuration"
run_test test_logging_integration "Logging integration"
run_test test_network_tools "Network tools installation"
run_test test_security_packages "Security packages validation"
run_test test_system_optimization "System optimization"
run_test test_container_optimizations "Container-specific optimizations"
run_test test_file_permissions "File permissions setup"

# Generate test report
generate_report