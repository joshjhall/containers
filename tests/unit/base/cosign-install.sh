#!/usr/bin/env bash
# Unit tests for lib/base/cosign-install.sh
# Tests cosign installation helper used by docker.sh and kubernetes.sh features

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Cosign Install Tests"

# Source file under test
SOURCE_FILE="$PROJECT_ROOT/lib/base/cosign-install.sh"

# Setup function - runs before each test
setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$RESULTS_DIR/test-cosign-install-$unique_id"
    mkdir -p "$TEST_TEMP_DIR"
    mkdir -p "$TEST_TEMP_DIR/bin"
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

# ============================================================================
# Static Analysis Tests
# ============================================================================

test_script_exists() {
    assert_file_exists "$SOURCE_FILE" "cosign-install.sh exists"
}

test_has_include_guard() {
    assert_file_contains "$SOURCE_FILE" "_COSIGN_INSTALL_LOADED" \
        "Script has include guard to prevent multiple sourcing"
}

test_defines_install_cosign() {
    assert_file_contains "$SOURCE_FILE" "install_cosign()" \
        "Script defines install_cosign function"
}

test_has_pinned_version() {
    assert_file_contains "$SOURCE_FILE" 'cosign_version=' \
        "Script pins cosign version"
}

test_uses_map_arch() {
    assert_file_contains "$SOURCE_FILE" "map_arch" \
        "Script uses map_arch for architecture detection"
}

test_calls_verify_download() {
    assert_file_contains "$SOURCE_FILE" "verify_download" \
        "Script calls verify_download for 4-tier verification"
}

test_downloads_from_sigstore() {
    assert_file_contains "$SOURCE_FILE" "github.com/sigstore/cosign" \
        "Script downloads from sigstore/cosign on GitHub"
}

test_has_already_installed_guard() {
    assert_file_contains "$SOURCE_FILE" "command -v cosign" \
        "Script checks if cosign is already installed"
}

test_sources_export_utils() {
    assert_file_contains "$SOURCE_FILE" "export-utils.sh" \
        "Script sources export-utils.sh"
}

# ============================================================================
# Functional Test - already-installed short-circuit path
# ============================================================================

test_already_installed_returns_zero() {
    local exit_code=0
    local output
    output=$(bash -c "
        # Create mock cosign binary so 'command -v cosign' succeeds
        mkdir -p '$TEST_TEMP_DIR/bin'
        command cat > '$TEST_TEMP_DIR/bin/cosign' <<'MOCK'
#!/usr/bin/env bash
echo 'cosign mock'
MOCK
        chmod +x '$TEST_TEMP_DIR/bin/cosign'
        export PATH='$TEST_TEMP_DIR/bin':\$PATH

        # Stub all dependencies that cosign-install.sh expects
        _COSIGN_INSTALL_LOADED=''
        log_message() { echo \"\$*\"; }
        log_error() { echo \"\$*\" >&2; }
        map_arch() { echo 'amd64'; }
        create_secure_temp_dir() { echo '/tmp/fake'; }
        log_command() { shift; \"\$@\"; }
        log_feature_end() { :; }
        fetch_github_checksums_txt() { :; }
        register_tool_checksum_fetcher() { :; }
        verify_download() { :; }
        protected_export() { :; }
        declare -A _TOOL_CHECKSUM_FETCHERS 2>/dev/null || true

        source '$SOURCE_FILE' 2>/dev/null
        install_cosign
    " 2>/dev/null) || exit_code=$?

    assert_equals "0" "$exit_code" "install_cosign returns 0 when cosign is already installed"
    assert_contains "$output" "already installed" \
        "install_cosign prints already-installed message"
}

# ============================================================================
# Run all tests
# ============================================================================

# Static analysis
run_test_with_setup test_script_exists "Script exists"
run_test_with_setup test_has_include_guard "Has include guard"
run_test_with_setup test_defines_install_cosign "Defines install_cosign function"
run_test_with_setup test_has_pinned_version "Has pinned cosign version"
run_test_with_setup test_uses_map_arch "Uses map_arch for architecture detection"
run_test_with_setup test_calls_verify_download "Calls verify_download for verification"
run_test_with_setup test_downloads_from_sigstore "Downloads from sigstore/cosign"
run_test_with_setup test_has_already_installed_guard "Has already-installed guard"
run_test_with_setup test_sources_export_utils "Sources export-utils.sh"

# Functional
run_test_with_setup test_already_installed_returns_zero "Already-installed path returns 0"

# Generate test report
generate_report
