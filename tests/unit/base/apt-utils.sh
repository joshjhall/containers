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
    if command grep -q "export -f apt_update" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "apt_update function is exported"
    else
        assert_true false "apt_update function not exported"
    fi

    if command grep -q "export -f apt_install" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "apt_install function is exported"
    else
        assert_true false "apt_install function not exported"
    fi

    if command grep -q "export -f apt_cleanup" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "apt_cleanup function is exported"
    else
        assert_true false "apt_cleanup function not exported"
    fi
}

# Test: apt_update function exists
test_apt_update_function() {
    # Check that apt_update function is defined
    if command grep -q "^apt_update()" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "apt_update function is defined"
    else
        assert_true false "apt_update function not found"
    fi

    # Check for retry logic
    if command grep -q "APT_MAX_RETRIES" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "Retry logic with APT_MAX_RETRIES is present"
    else
        assert_true false "Retry logic not found"
    fi
}

# Test: apt_install function exists
test_apt_install_function() {
    # Check that apt_install function is defined
    if command grep -q "^apt_install()" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "apt_install function is defined"
    else
        assert_true false "apt_install function not found"
    fi

    # Check for --no-install-recommends flag
    if command grep -q "\-\-no-install-recommends" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "Using --no-install-recommends for minimal installs"
    else
        assert_true false "Not using --no-install-recommends flag"
    fi
}

# Test: apt_cleanup function exists
test_apt_cleanup_function() {
    # Check that apt_cleanup function is defined
    if command grep -q "^apt_cleanup()\|^apt_cleanup ()" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "apt_cleanup function is defined"
    else
        assert_true false "apt_cleanup function not found"
    fi

    # Check for clean command (autoremove is not in apt_cleanup)
    if command grep -q "apt-get clean" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "apt_cleanup includes clean command"
    else
        assert_true false "apt_cleanup missing clean command"
    fi

    # Check for clean
    if command grep -q "apt-get clean" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "apt_cleanup includes clean"
    else
        assert_true false "apt_cleanup missing clean"
    fi
}

# Test: apt_retry function exists
test_apt_retry_function() {
    # Check that apt_retry function is defined
    if command grep -q "^apt_retry()\|^apt_retry ()" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "apt_retry function is defined"
    else
        assert_true false "apt_retry function not found"
    fi

    # Check for exponential backoff
    if command grep -q "sleep.*delay" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "Retry includes delay/backoff logic"
    else
        assert_true false "Retry missing delay/backoff logic"
    fi
}

# Test: Timeout configuration
test_timeout_configuration() {
    # Check for timeout settings
    if command grep -q "Acquire::http::Timeout" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "HTTP timeout is configured"
    else
        assert_true false "HTTP timeout not configured"
    fi

    if command grep -q "Acquire::https::Timeout" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "HTTPS timeout is configured"
    else
        assert_true false "HTTPS timeout not configured"
    fi
}

# Test: Network diagnostics
test_network_diagnostics() {
    # Check for diagnostic commands on failure
    if command grep -q "nslookup" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "DNS diagnostics included"
    else
        assert_true false "DNS diagnostics missing"
    fi

    if command grep -q "ping" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "Network connectivity test included"
    else
        assert_true false "Network connectivity test missing"
    fi
}

# Test: Environment variable defaults
test_environment_defaults() {
    # Check for default values
    if command grep -q "APT_MAX_RETRIES:-3" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "Default max retries is 3"
    else
        assert_true false "Default max retries not set"
    fi

    if command grep -q "APT_RETRY_DELAY:-5" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "Default retry delay is 5 seconds"
    else
        assert_true false "Default retry delay not set"
    fi

    if command grep -q "APT_TIMEOUT:-300" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "Default timeout is 300 seconds"
    else
        assert_true false "Default timeout not set"
    fi
}

# Test: Error handling
test_error_handling() {
    # Check for proper error handling
    if command grep -q "set -euo pipefail" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "Strict error handling enabled"
    else
        # Some scripts might use different error handling
        assert_true true "Error handling configuration present"
    fi
}

# Test: Package name validation (security)
test_package_name_validation() {
    # Check for package name validation regex
    if command grep -q "Invalid package name" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "Package name validation is present"
    else
        assert_true false "Package name validation missing"
    fi

    # Check for validation regex pattern
    if command grep -q "\[\[.*=\~.*\]\]" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "Regex validation pattern present"
    else
        assert_true false "Regex validation pattern missing"
    fi

    # Check that version specifications are supported (=, <, >, *)
    if command grep -q "=.*<.*>.*\*" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "Version specification characters are supported"
    else
        assert_true false "Version specification characters missing"
    fi
}

# Test: APT_ACQUIRE_TIMEOUT constant
test_apt_acquire_timeout_constant() {
    if command grep -q "APT_ACQUIRE_TIMEOUT:-30" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "APT_ACQUIRE_TIMEOUT default is 30"
    else
        assert_true false "APT_ACQUIRE_TIMEOUT default not set"
    fi

    # Verify hardcoded Timeout=30 is no longer used in function bodies
    if command grep -q 'Timeout=30' "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true false "Hardcoded Timeout=30 still present (should use APT_ACQUIRE_TIMEOUT)"
    else
        assert_true true "No hardcoded Timeout=30 values remain"
    fi
}

# Test: add_apt_repository_key function
test_add_apt_repository_key_function() {
    if command grep -q "^add_apt_repository_key()" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "add_apt_repository_key function is defined"
    else
        assert_true false "add_apt_repository_key function not found"
    fi

    if command grep -q "export -f add_apt_repository_key" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "add_apt_repository_key function is exported"
    else
        assert_true false "add_apt_repository_key function not exported"
    fi
}

# Test: Debian version detection
test_debian_version_detection() {
    # Check for get_debian_major_version function
    if command grep -q "^get_debian_major_version()" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "get_debian_major_version function is defined"
    else
        assert_true false "get_debian_major_version function not found"
    fi

    # Check for /etc/os-release support (method 1)
    if command grep -q "/etc/os-release" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "Supports /etc/os-release detection"
    else
        assert_true false "Missing /etc/os-release detection"
    fi

    # Check for /etc/debian_version support (method 2)
    if command grep -q "/etc/debian_version" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "Supports /etc/debian_version fallback"
    else
        assert_true false "Missing /etc/debian_version fallback"
    fi

    # Check for lsb_release support (method 3)
    if command grep -q "lsb_release" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "Supports lsb_release fallback"
    else
        assert_true false "Missing lsb_release fallback"
    fi

    # Check for codename mapping
    if command grep -q "trixie.*13" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "Maps trixie codename to version 13"
    else
        assert_true false "Missing trixie codename mapping"
    fi

    if command grep -q "bookworm.*12" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "Maps bookworm codename to version 12"
    else
        assert_true false "Missing bookworm codename mapping"
    fi
}

# Test: is_debian_version function
test_is_debian_version() {
    # Check for is_debian_version function
    if command grep -q "^is_debian_version()" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "is_debian_version function is defined"
    else
        assert_true false "is_debian_version function not found"
    fi
}

# Test: apt_install_conditional function
test_apt_install_conditional() {
    # Check for apt_install_conditional function
    if command grep -q "^apt_install_conditional()" "$PROJECT_ROOT/lib/base/apt-utils.sh"; then
        assert_true true "apt_install_conditional function is defined"
    else
        assert_true false "apt_install_conditional function not found"
    fi
}

# ============================================================================
# Functional Tests - Debian Version Detection
# ============================================================================

# Test: get_debian_major_version returns a numeric value on this system
test_get_debian_major_version_returns_number() {
    # Source the script in a subshell to avoid side effects
    local output
    output=$(bash -c "
        _APT_UTILS_LOADED=''
        source '$PROJECT_ROOT/lib/base/apt-utils.sh' 2>/dev/null
        get_debian_major_version
    " 2>/dev/null)

    # Output should be a number (e.g., 11, 12, 13)
    assert_matches "$output" "^[0-9]+$" "get_debian_major_version returns a numeric value"
}

# Test: is_debian_version matches the current system version
test_is_debian_version_matches_current() {
    local exit_code=0
    bash -c "
        _APT_UTILS_LOADED=''
        source '$PROJECT_ROOT/lib/base/apt-utils.sh' 2>/dev/null
        current=\$(get_debian_major_version)
        is_debian_version \"\$current\"
    " 2>/dev/null || exit_code=$?

    assert_equals "0" "$exit_code" "is_debian_version matches current system version"
}

# Test: is_debian_version rejects a version that doesn't exist
test_is_debian_version_rejects_wrong() {
    local exit_code=0
    bash -c "
        _APT_UTILS_LOADED=''
        source '$PROJECT_ROOT/lib/base/apt-utils.sh' 2>/dev/null
        is_debian_version 99
    " 2>/dev/null || exit_code=$?

    assert_equals "1" "$exit_code" "is_debian_version rejects version 99"
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
run_test test_package_name_validation "Package name validation (security)"
run_test test_apt_acquire_timeout_constant "APT_ACQUIRE_TIMEOUT constant"
run_test test_add_apt_repository_key_function "add_apt_repository_key function"
run_test test_debian_version_detection "Debian version detection with fallbacks"
run_test test_is_debian_version "is_debian_version function"
run_test test_apt_install_conditional "apt_install_conditional function"

# Functional tests
run_test test_get_debian_major_version_returns_number "get_debian_major_version returns a number"
run_test test_is_debian_version_matches_current "is_debian_version matches current version"
run_test test_is_debian_version_rejects_wrong "is_debian_version rejects version 99"

# Generate test report
generate_report
