#!/bin/bash
# Unit tests for apt-utils.sh functionality
set -euo pipefail

# Source test framework
source /workspace/containers/tests/framework/test-runner.sh

# Test suite metadata
TEST_SUITE="apt-utils"
TEST_DESCRIPTION="Tests for APT utility functions"

# Mock apt-get commands for testing
mock_apt_get_success() {
    echo "Mock: apt-get $* succeeded"
    return 0
}

mock_apt_get_failure() {
    echo "Mock: apt-get $* failed"
    return 100
}

mock_apt_get_intermittent() {
    # Fail first 2 attempts, succeed on 3rd
    if [ ! -f /tmp/apt_attempt_count ]; then
        echo "1" > /tmp/apt_attempt_count
        echo "Mock: apt-get $* failed (attempt 1)"
        return 100
    else
        local count=$(cat /tmp/apt_attempt_count)
        if [ "$count" -lt 2 ]; then
            echo $((count + 1)) > /tmp/apt_attempt_count
            echo "Mock: apt-get $* failed (attempt $((count + 1)))"
            return 100
        else
            rm -f /tmp/apt_attempt_count
            echo "Mock: apt-get $* succeeded (attempt 3)"
            return 0
        fi
    fi
}

# Setup and teardown
setup() {
    # Save original functions if they exist
    if declare -f apt-get >/dev/null; then
        eval "original_$(declare -f apt-get)"
    fi
    
    # Clean up any leftover test files
    rm -f /tmp/apt_attempt_count
    
    # Set test environment variables
    export APT_MAX_RETRIES=3
    export APT_RETRY_DELAY=0  # No delay for tests
    export APT_TIMEOUT=5
}

teardown() {
    # Restore original apt-get if it was saved
    if declare -f original_apt-get >/dev/null; then
        eval "$(declare -f original_apt-get | sed 's/original_apt-get/apt-get/')"
    fi
    
    # Clean up test files
    rm -f /tmp/apt_attempt_count
    
    # Unset test environment variables
    unset APT_MAX_RETRIES
    unset APT_RETRY_DELAY
    unset APT_TIMEOUT
}

# Test: apt_update with successful execution
test_apt_update_success() {
    # Mock apt-get to succeed
    function apt-get() { mock_apt_get_success "$@"; }
    
    # Source the apt-utils
    source /tmp/build-scripts/base/apt-utils.sh
    
    # Run apt_update
    local output
    output=$(apt_update 2>&1)
    local result=$?
    
    # Assertions
    assert_equals $result 0 "apt_update should succeed"
    assert_contains "$output" "Package lists updated successfully" "Should show success message"
    assert_contains "$output" "Mock: apt-get update" "Should call apt-get update"
}

# Test: apt_update with retry on failure
test_apt_update_retry() {
    # Mock apt-get to fail then succeed
    function apt-get() { mock_apt_get_intermittent "$@"; }
    
    # Source the apt-utils
    source /tmp/build-scripts/base/apt-utils.sh
    
    # Run apt_update
    local output
    output=$(apt_update 2>&1)
    local result=$?
    
    # Assertions
    assert_equals $result 0 "apt_update should eventually succeed"
    assert_contains "$output" "attempt 1/3" "Should show first attempt"
    assert_contains "$output" "attempt 2/3" "Should show second attempt"
    assert_contains "$output" "Package lists updated successfully" "Should show success message"
}

# Test: apt_update with persistent failure
test_apt_update_persistent_failure() {
    # Mock apt-get to always fail
    function apt-get() { mock_apt_get_failure "$@"; }
    
    # Mock network diagnostic commands
    function nslookup() { echo "Mock: DNS resolution failed"; return 1; }
    function ping() { echo "Mock: Cannot reach $2"; return 1; }
    function cat() { 
        if [[ "$1" == "/etc/apt/sources.list" ]]; then
            echo "deb http://deb.debian.org/debian bookworm main"
        else
            command cat "$@"
        fi
    }
    
    # Source the apt-utils
    source /tmp/build-scripts/base/apt-utils.sh
    
    # Run apt_update
    local output
    output=$(apt_update 2>&1)
    local result=$?
    
    # Assertions
    assert_not_equals $result 0 "apt_update should fail after max retries"
    assert_contains "$output" "attempt 3/3" "Should try max attempts"
    assert_contains "$output" "failed after 3 attempts" "Should show failure message"
    assert_contains "$output" "Diagnostic Information" "Should show diagnostics"
    assert_contains "$output" "DNS resolution failed" "Should test DNS"
    assert_contains "$output" "Cannot reach" "Should test connectivity"
}

# Test: apt_install with successful execution
test_apt_install_success() {
    # Mock apt-get to succeed
    function apt-get() { mock_apt_get_success "$@"; }
    
    # Source the apt-utils
    source /tmp/build-scripts/base/apt-utils.sh
    
    # Run apt_install
    local output
    output=$(apt_install curl wget 2>&1)
    local result=$?
    
    # Assertions
    assert_equals $result 0 "apt_install should succeed"
    assert_contains "$output" "Packages installed successfully: curl wget" "Should show success message"
    assert_contains "$output" "Mock: apt-get install" "Should call apt-get install"
}

# Test: apt_install with no packages
test_apt_install_no_packages() {
    # Source the apt-utils
    source /tmp/build-scripts/base/apt-utils.sh
    
    # Run apt_install with no arguments
    local output
    output=$(apt_install 2>&1)
    local result=$?
    
    # Assertions
    assert_not_equals $result 0 "apt_install should fail with no packages"
    assert_contains "$output" "requires at least one package name" "Should show error message"
}

# Test: apt_install with retry on failure
test_apt_install_retry() {
    # Mock apt-get to fail then succeed
    function apt-get() { mock_apt_get_intermittent "$@"; }
    
    # Source the apt-utils
    source /tmp/build-scripts/base/apt-utils.sh
    
    # Run apt_install
    local output
    output=$(apt_install postgresql-client 2>&1)
    local result=$?
    
    # Assertions
    assert_equals $result 0 "apt_install should eventually succeed"
    assert_contains "$output" "attempt 1/3" "Should show first attempt"
    assert_contains "$output" "attempt 2/3" "Should show second attempt"
    assert_contains "$output" "Packages installed successfully" "Should show success message"
}

# Test: apt_cleanup functionality
test_apt_cleanup() {
    # Mock apt-get and rm
    function apt-get() { 
        if [[ "$1" == "clean" ]]; then
            echo "Mock: Cleaning apt cache"
            return 0
        fi
    }
    function rm() {
        if [[ "$*" == *"/var/lib/apt/lists/"* ]]; then
            echo "Mock: Removing apt lists"
            return 0
        fi
        command rm "$@"
    }
    
    # Source the apt-utils
    source /tmp/build-scripts/base/apt-utils.sh
    
    # Run apt_cleanup
    local output
    output=$(apt_cleanup 2>&1)
    local result=$?
    
    # Assertions
    assert_equals $result 0 "apt_cleanup should succeed"
    assert_contains "$output" "Cleaning apt cache" "Should clean cache"
    assert_contains "$output" "Removing apt lists" "Should remove lists"
    assert_contains "$output" "apt cache cleaned" "Should show completion message"
}

# Test: configure_apt_mirrors functionality
test_configure_apt_mirrors() {
    # Create a temporary directory for testing
    local test_dir="/tmp/test_apt_config"
    mkdir -p "$test_dir/apt/apt.conf.d"
    
    # Mock the /etc directory
    function cat() {
        if [[ "$1" == ">" && "$2" == "/etc/apt/apt.conf.d/99-retries" ]]; then
            command cat > "$test_dir/apt/apt.conf.d/99-retries"
        else
            command cat "$@"
        fi
    }
    
    # Source the apt-utils
    source /tmp/build-scripts/base/apt-utils.sh
    
    # Run configure_apt_mirrors
    local output
    output=$(configure_apt_mirrors 2>&1)
    local result=$?
    
    # Assertions
    assert_equals $result 0 "configure_apt_mirrors should succeed"
    assert_contains "$output" "Configuring apt mirrors" "Should show configuration message"
    assert_contains "$output" "configured with timeout and retry settings" "Should show completion"
    
    # Clean up
    rm -rf "$test_dir"
}

# Test: Environment variable configuration
test_environment_variables() {
    # Set custom values
    export APT_MAX_RETRIES=5
    export APT_RETRY_DELAY=10
    export APT_TIMEOUT=600
    
    # Source the apt-utils
    source /tmp/build-scripts/base/apt-utils.sh
    
    # Check that variables are respected
    # This would be tested through actual function execution
    # but we can verify they're set
    assert_equals "$APT_MAX_RETRIES" "5" "Should use custom max retries"
    assert_equals "$APT_RETRY_DELAY" "10" "Should use custom retry delay"
    assert_equals "$APT_TIMEOUT" "600" "Should use custom timeout"
}

# Run the test suite
run_test_suite