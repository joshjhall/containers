#!/usr/bin/env bash
# Unit tests for lib/base/cosign-require.sh
#
# cosign-require.sh asserts that the base-installed cosign (lib/base/setup.sh,
# pinned COSIGN_VERSION) is on PATH. It deliberately does NOT install cosign:
# the second, separately-pinned .deb install this file used to perform was dead
# code, and its drifting 3.0.2 pin was invisible to bin/check-versions.sh (#935).
#
# The negative assertions below are load-bearing — they are what fails if a
# second cosign install path is ever reintroduced, which would silently widen
# the scope of the global CVE-2026-56854 entry in .trivyignore beyond the binary
# its symbol-table evidence was established against.

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Cosign Require Tests"

# Source file under test
SOURCE_FILE="$PROJECT_ROOT/lib/base/cosign-require.sh"

# Setup function - runs before each test
setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$TEST_SCRATCH_BASE/test-cosign-require-$unique_id"
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

# run_require_cosign - Source the helper in a clean subshell and call it
#
# Stubs only the logging functions the helper genuinely uses, so a future
# dependency on an unstubbed helper surfaces as a failure rather than being
# absorbed by a permissive stub set. PATH is replaced (not prepended) so the
# absent-cosign case cannot accidentally find the real container's cosign.
#
# Args:
#   $1: "present" to place a mock cosign on PATH, "absent" for an empty PATH
#
# Echoes the helper's combined output; returns the helper's exit code.
run_require_cosign() {
    local mode="$1"
    local stub_bin="$TEST_TEMP_DIR/bin"

    if [ "$mode" = "present" ]; then
        command cat >"$stub_bin/cosign" <<'MOCK'
#!/usr/bin/env bash
echo 'cosign mock'
MOCK
        chmod +x "$stub_bin/cosign"
    fi

    # A minimal PATH containing only the stub dir: 'command -v cosign' then
    # answers purely from what this test placed there. Bash builtins used by
    # the helper (command, return) need no external binaries.
    bash -c "
        export PATH='$stub_bin'
        _COSIGN_REQUIRE_LOADED=''
        log_message() { echo \"\$*\"; }
        log_error() { echo \"\$*\"; }
        protected_export() { :; }

        source '$SOURCE_FILE'
        require_cosign
    " 2>&1
}

# ============================================================================
# Static Analysis Tests
# ============================================================================

test_script_exists() {
    assert_file_exists "$SOURCE_FILE" "cosign-require.sh exists"
}

test_has_include_guard() {
    assert_file_contains "$SOURCE_FILE" "_COSIGN_REQUIRE_LOADED" \
        "Script has include guard to prevent multiple sourcing"
}

test_defines_require_cosign() {
    assert_file_contains "$SOURCE_FILE" "require_cosign()" \
        "Script defines require_cosign function"
}

test_sources_export_utils() {
    assert_file_contains "$SOURCE_FILE" "export-utils.sh" \
        "Script sources export-utils.sh"
}

# ============================================================================
# Negative Assertions - no second cosign install path (#935)
# ============================================================================
# These pin the consolidation. cosign is installed exactly once, by
# lib/base/setup.sh at the tracked COSIGN_VERSION; reintroducing an install
# here would restore an untracked pin and silently widen the .trivyignore
# CVE-2026-56854 suppression to a binary it was never proven against.

# Matches dpkg only as a command, not the word inside the header comment that
# explains why the install was removed. Anchoring on '^[^#]*dpkg' keeps the
# assertion about code while letting the rationale stay documented in place.
test_does_not_install_via_dpkg() {
    assert_file_not_contains "$SOURCE_FILE" "^[^#]*dpkg" \
        "Script does not dpkg-install a second cosign (#935)"
}

test_does_not_download() {
    assert_file_not_contains "$SOURCE_FILE" "verify_download" \
        "Script does not download a cosign artifact (#935)"
}

test_has_no_second_version_pin() {
    assert_file_not_contains "$SOURCE_FILE" "cosign_version=" \
        "Script pins no cosign version of its own — setup.sh owns COSIGN_VERSION (#935)"
}

test_does_not_reference_sigstore_releases() {
    assert_file_not_contains "$SOURCE_FILE" "github.com/sigstore/cosign" \
        "Script fetches nothing from sigstore/cosign releases (#935)"
}

# ============================================================================
# Functional Tests - the availability assertion itself
# ============================================================================

test_present_returns_zero() {
    local exit_code=0
    local output
    output=$(run_require_cosign "present") || exit_code=$?

    assert_equals "0" "$exit_code" "require_cosign returns 0 when cosign is on PATH"
    assert_contains "$output" "base install" \
        "require_cosign reports it is using the base-installed cosign"
}

# The discriminating case: without the 'command -v cosign' guard in
# require_cosign, this test fails (the helper would return 0 with no error).
# That is the standing proof that this suite tests something.
test_absent_returns_one() {
    local exit_code=0
    local output
    output=$(run_require_cosign "absent") || exit_code=$?

    assert_equals "1" "$exit_code" "require_cosign returns 1 when cosign is missing"
    assert_contains "$output" "not found" \
        "require_cosign reports cosign was not found"
    assert_contains "$output" "setup.sh" \
        "Error names lib/base/setup.sh as the install owner, so the fix is actionable"
}

# require_cosign must not install anything as a side effect — a missing cosign
# is a build-stage regression to surface, not something to paper over.
test_absent_does_not_create_cosign() {
    run_require_cosign "absent" >/dev/null 2>&1 || true

    assert_file_not_exists "$TEST_TEMP_DIR/bin/cosign" \
        "require_cosign installs nothing when cosign is absent (#935)"
}

# ============================================================================
# Run all tests
# ============================================================================

# Static analysis
run_test_with_setup test_script_exists "Script exists"
run_test_with_setup test_has_include_guard "Has include guard"
run_test_with_setup test_defines_require_cosign "Defines require_cosign function"
run_test_with_setup test_sources_export_utils "Sources export-utils.sh"

# Negative assertions (#935)
run_test_with_setup test_does_not_install_via_dpkg "Does not dpkg-install cosign"
run_test_with_setup test_does_not_download "Does not download cosign"
run_test_with_setup test_has_no_second_version_pin "Has no second version pin"
run_test_with_setup test_does_not_reference_sigstore_releases "No sigstore release URL"

# Functional
run_test_with_setup test_present_returns_zero "Present: returns 0 and reports base install"
run_test_with_setup test_absent_returns_one "Absent: returns 1 with actionable error"
run_test_with_setup test_absent_does_not_create_cosign "Absent: installs nothing"

# Generate test report
generate_report
