#!/usr/bin/env bash
# Unit tests for lib/base/fixuid.sh
# Tests fixuid installation script functionality

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Base Fixuid Installation Tests"

# Setup function
setup() {
    export TEST_TEMP_DIR="$RESULTS_DIR/test-fixuid-$$"
    mkdir -p "$TEST_TEMP_DIR"
}

# Teardown function
teardown() {
    rm -rf "$TEST_TEMP_DIR" 2>/dev/null || true
}

# Test: Script has valid bash syntax
test_fixuid_syntax() {
    local script="$CONTAINERS_DIR/lib/base/fixuid.sh"

    if bash -n "$script" 2>/dev/null; then
        assert_true true "fixuid.sh has valid bash syntax"
    else
        assert_true false "fixuid.sh has syntax errors"
    fi
}

# Test: Script is executable
test_fixuid_executable() {
    local script="$CONTAINERS_DIR/lib/base/fixuid.sh"

    if [ -x "$script" ]; then
        assert_true true "fixuid.sh is executable"
    else
        assert_true false "fixuid.sh is not executable"
    fi
}

# Test: Version variable is defined
test_fixuid_version_defined() {
    local script="$CONTAINERS_DIR/lib/base/fixuid.sh"

    if grep -q "FIXUID_VERSION=" "$script"; then
        assert_true true "FIXUID_VERSION is defined in script"
    else
        assert_true false "FIXUID_VERSION not found in script"
    fi
}

# Test: Version format is valid (semver)
test_fixuid_version_format() {
    local script="$CONTAINERS_DIR/lib/base/fixuid.sh"

    # Extract version from the script (handles ${VAR:-default} pattern)
    local version
    version=$(grep "FIXUID_VERSION=" "$script" | head -1 | sed 's/.*:-\([0-9.]*\)}.*/\1/' | tr -d '"')

    # Check if version matches semver pattern (X.Y.Z or X.Y)
    if [[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        assert_true true "FIXUID_VERSION has valid semver format: $version"
    else
        assert_true false "FIXUID_VERSION has invalid format: $version"
    fi
}

# Test: Architecture detection covers common architectures
test_fixuid_arch_detection() {
    local script="$CONTAINERS_DIR/lib/base/fixuid.sh"

    local has_amd64=false
    local has_arm64=false

    if grep -q "x86_64.*amd64" "$script"; then
        has_amd64=true
    fi

    if grep -q "aarch64.*arm64" "$script"; then
        has_arm64=true
    fi

    if [ "$has_amd64" = true ] && [ "$has_arm64" = true ]; then
        assert_true true "Script handles amd64 and arm64 architectures"
    else
        assert_true false "Script missing architecture support (amd64=$has_amd64, arm64=$has_arm64)"
    fi
}

# Test: Download URL uses correct GitHub releases pattern
test_fixuid_download_url() {
    local script="$CONTAINERS_DIR/lib/base/fixuid.sh"

    if grep -q "github.com/boxboat/fixuid/releases" "$script"; then
        assert_true true "Script uses correct GitHub releases URL"
    else
        assert_true false "Script doesn't use GitHub releases URL"
    fi
}

# Test: Config file path is correct
test_fixuid_config_path() {
    local script="$CONTAINERS_DIR/lib/base/fixuid.sh"

    if grep -q "/etc/fixuid/config.yml" "$script"; then
        assert_true true "Script creates config at /etc/fixuid/config.yml"
    else
        assert_true false "Script doesn't create config at expected path"
    fi
}

# Test: Setuid bit is set (4755 permissions)
test_fixuid_setuid_permissions() {
    local script="$CONTAINERS_DIR/lib/base/fixuid.sh"

    if grep -q "chmod 4755" "$script"; then
        assert_true true "Script sets setuid bit (4755) on fixuid binary"
    else
        assert_true false "Script doesn't set setuid bit"
    fi
}

# Test: Script handles unsupported architectures gracefully
test_fixuid_unsupported_arch_handling() {
    local script="$CONTAINERS_DIR/lib/base/fixuid.sh"

    # Check for a fallback/warning case for unsupported architectures
    if grep -q "Unsupported architecture\|exit 0" "$script"; then
        assert_true true "Script handles unsupported architectures gracefully"
    else
        assert_true false "Script may not handle unsupported architectures"
    fi
}

# Test: Script sources build-env if available
test_fixuid_sources_build_env() {
    local script="$CONTAINERS_DIR/lib/base/fixuid.sh"

    if grep -q "source /tmp/build-env\|/tmp/build-env" "$script"; then
        assert_true true "Script sources build-env for USERNAME"
    else
        assert_true false "Script doesn't source build-env"
    fi
}

# Run all tests
run_test test_fixuid_syntax "Script has valid bash syntax"
run_test test_fixuid_executable "Script is executable"
run_test test_fixuid_version_defined "Version variable is defined"
run_test test_fixuid_version_format "Version format is valid"
run_test test_fixuid_arch_detection "Architecture detection is complete"
run_test test_fixuid_download_url "Download URL is correct"
run_test test_fixuid_config_path "Config path is correct"
run_test test_fixuid_setuid_permissions "Setuid permissions are set"
run_test test_fixuid_unsupported_arch_handling "Unsupported architectures handled"
run_test test_fixuid_sources_build_env "Build environment is sourced"

# Generate report
generate_report
