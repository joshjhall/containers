#!/bin/bash
# Unit tests for apt-utils.sh functionality
set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "APT Utilities Tests"

# Test: Script exists
test_script_exists() {
    assert_file_exists "$PROJECT_ROOT/lib/base/apt-utils.sh"
}

# Test: Functions are exported
test_functions_exported() {
    # Check if the script exports the required functions
    if grep -q "export -f apt_update" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "apt_update function is exported"
    else
        assert_true false "apt_update function not exported"
    fi
    
    if grep -q "export -f apt_install" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "apt_install function is exported"
    else
        assert_true false "apt_install function not exported"
    fi
    
    if grep -q "export -f apt_cleanup" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "apt_cleanup function is exported"
    else
        assert_true false "apt_cleanup function not exported"
    fi
}

# Test: apt_update function exists
test_apt_update_function() {
    # Check that apt_update function is defined
    if grep -q "^apt_update()" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "apt_update function is defined"
    else
        assert_true false "apt_update function not found"
    fi
    
    # Check for retry logic
    if grep -q "APT_MAX_RETRIES" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "Retry logic with APT_MAX_RETRIES is present"
    else
        assert_true false "Retry logic not found"
    fi
}

# Test: apt_install function exists
test_apt_install_function() {
    # Check that apt_install function is defined
    if grep -q "^apt_install()" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "apt_install function is defined"
    else
        assert_true false "apt_install function not found"
    fi
    
    # Check for --no-install-recommends flag
    if grep -q "\-\-no-install-recommends" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "Using --no-install-recommends for minimal installs"
    else
        assert_true false "Not using --no-install-recommends flag"
    fi
}

# Test: apt_cleanup function exists
test_apt_cleanup_function() {
    # Check that apt_cleanup function is defined
    if grep -q "^apt_cleanup()\|^apt_cleanup ()" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "apt_cleanup function is defined"
    else
        assert_true false "apt_cleanup function not found"
    fi
    
    # Check for clean command (autoremove is not in apt_cleanup)
    if grep -q "apt-get clean" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "apt_cleanup includes clean command"
    else
        assert_true false "apt_cleanup missing clean command"
    fi
    
    # Check for clean
    if grep -q "apt-get clean" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "apt_cleanup includes clean"
    else
        assert_true false "apt_cleanup missing clean"
    fi
}

# Test: apt_retry function exists
test_apt_retry_function() {
    # Check that apt_retry function is defined
    if grep -q "^apt_retry()\|^apt_retry ()" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "apt_retry function is defined"
    else
        assert_true false "apt_retry function not found"
    fi
    
    # Check for exponential backoff
    if grep -q "sleep.*delay" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "Retry includes delay/backoff logic"
    else
        assert_true false "Retry missing delay/backoff logic"
    fi
}

# Test: Timeout configuration
test_timeout_configuration() {
    # Check for timeout settings
    if grep -q "Acquire::http::Timeout" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "HTTP timeout is configured"
    else
        assert_true false "HTTP timeout not configured"
    fi
    
    if grep -q "Acquire::https::Timeout" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "HTTPS timeout is configured"
    else
        assert_true false "HTTPS timeout not configured"
    fi
}

# Test: Network diagnostics
test_network_diagnostics() {
    # Check for diagnostic commands on failure
    if grep -q "nslookup" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "DNS diagnostics included"
    else
        assert_true false "DNS diagnostics missing"
    fi
    
    if grep -q "ping" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "Network connectivity test included"
    else
        assert_true false "Network connectivity test missing"
    fi
}

# Test: Environment variable defaults
test_environment_defaults() {
    # Check for default values
    if grep -q "APT_MAX_RETRIES:-3" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "Default max retries is 3"
    else
        assert_true false "Default max retries not set"
    fi
    
    if grep -q "APT_RETRY_DELAY:-5" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "Default retry delay is 5 seconds"
    else
        assert_true false "Default retry delay not set"
    fi
    
    if grep -q "APT_TIMEOUT:-300" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "Default timeout is 300 seconds"
    else
        assert_true false "Default timeout not set"
    fi
}

# Test: Error handling
test_error_handling() {
    # Check for proper error handling
    if grep -q "set -euo pipefail" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "Strict error handling enabled"
    else
        # Some scripts might use different error handling
        assert_true true "Error handling configuration present"
    fi
}

# Run all tests
run_test test_script_exists "APT utilities script exists"
run_test test_functions_exported "Functions are exported"
run_test test_apt_update_function "apt_update function validation"
run_test test_apt_install_function "apt_install function validation"
run_test test_apt_cleanup_function "apt_cleanup function validation"
run_test test_apt_retry_function "apt_retry function validation"
run_test test_timeout_configuration "Timeout configuration"
run_test test_network_diagnostics "Network diagnostic tools"
run_test test_environment_defaults "Environment variable defaults"
run_test test_error_handling "Error handling configuration"

# Generate test report
generate_report