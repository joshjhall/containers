#!/usr/bin/env bash
# Unit tests for lib/base/cosign-require.sh
#
# cosign-require.sh asserts that PATH resolves cosign to the base install
# (lib/base/setup.sh, pinned COSIGN_VERSION, /usr/local/bin/cosign) and rejects
# a cosign found anywhere else (#940). It deliberately does NOT install cosign:
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
#   $2: value assigned to _COSIGN_BASE_PATH AFTER sourcing (the test seam),
#       or "" to keep the helper's own /usr/local/bin/cosign
#   $3: value exported as _COSIGN_BASE_PATH BEFORE sourcing, or "" for none —
#       used to prove the build environment cannot widen the pin
#
# Echoes the helper's combined output; returns the helper's exit code.
run_require_cosign() {
    local mode="$1"
    local base_path="${2:-}"
    local pre_env="${3:-}"
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
    # the helper (command, local, return) need no external binaries.
    bash -c "
        export PATH='$stub_bin'
        _COSIGN_REQUIRE_LOADED=''
        if [ -n '$pre_env' ]; then export _COSIGN_BASE_PATH='$pre_env'; fi
        log_message() { echo \"\$*\"; }
        log_error() { echo \"\$*\"; }
        protected_export() { :; }

        source '$SOURCE_FILE'
        if [ -n '$base_path' ]; then _COSIGN_BASE_PATH='$base_path'; fi
        require_cosign
    " 2>&1
}

# run_require_cosign_with - Run require_cosign under a caller-built environment
#
# The two-cosign and shell-function cases need more than one stub dir or a
# preamble before the call, which run_require_cosign's three positional modes
# do not express. Same clean-subshell rules: logging stubbed, PATH replaced.
#
# Args:
#   $1: PATH for the subshell (colon-separated, in lookup order)
#   $2: value assigned to _COSIGN_BASE_PATH after sourcing
#   $3: shell code run after sourcing, before require_cosign (may be "")
#
# After require_cosign, prints "COSIGN_BIN=<value>" or "COSIGN_BIN unset", so
# tests can assert the exported contract. Returns require_cosign's exit code.
run_require_cosign_with() {
    local path="$1"
    local base_path="$2"
    local preamble="${3:-}"

    bash -c "
        export PATH='$path'
        _COSIGN_REQUIRE_LOADED=''
        log_message() { echo \"\$*\"; }
        log_error() { echo \"\$*\"; }
        protected_export() { :; }

        source '$SOURCE_FILE'
        _COSIGN_BASE_PATH='$base_path'
        $preamble
        rc=0
        require_cosign || rc=\$?
        if [ -n \"\${COSIGN_BIN+set}\" ]; then
            echo \"COSIGN_BIN=\$COSIGN_BIN\"
        else
            echo 'COSIGN_BIN unset'
        fi
        exit \$rc
    " 2>&1
}

# write_cosign_stub - Create an executable mock cosign at the given path
write_cosign_stub() {
    command mkdir -p "$(command dirname "$1")"
    command printf '#!/usr/bin/env bash\necho cosign mock\n' >"$1"
    command chmod +x "$1"
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
    output=$(run_require_cosign "present" "$TEST_TEMP_DIR/bin/cosign") || exit_code=$?

    assert_equals "0" "$exit_code" \
        "require_cosign returns 0 when cosign resolves to the base install path"
    assert_contains "$output" "Using cosign from base install: $TEST_TEMP_DIR/bin/cosign" \
        "require_cosign reports the resolved base-installed cosign"
}

# The #940 discriminator: a cosign that is on PATH but NOT at the base install
# location must be rejected. Without the resolved-path check in require_cosign
# this returns 0 — the same stub passes test_present_returns_zero above, so the
# only difference between the two cases is where the pin points.
test_present_outside_base_returns_one() {
    local exit_code=0
    local output
    output=$(run_require_cosign "present" "$TEST_TEMP_DIR/base/cosign") || exit_code=$?

    assert_equals "1" "$exit_code" \
        "require_cosign returns 1 when cosign resolves outside the base install (#940)"
    assert_contains "$output" "cosign resolved to $TEST_TEMP_DIR/bin/cosign, not the base install at $TEST_TEMP_DIR/base/cosign" \
        "Error names both the substitute path and the expected base path"
    assert_not_contains "$output" "Using cosign" \
        "require_cosign does not report using the substitute"
}

# A real PATH-order shadow (#1029): two cosigns exist, the base one at the
# pinned location and a substitute in a directory earlier on PATH. Unlike
# test_present_outside_base_returns_one, the pinned binary is really there, so
# this proves PATH order alone is enough to be rejected. Without the
# resolved-path check this returns 0.
test_path_order_shadow_returns_one() {
    local shadow="$TEST_TEMP_DIR/shadow/cosign"
    local pinned="$TEST_TEMP_DIR/bin/cosign"
    write_cosign_stub "$shadow"
    write_cosign_stub "$pinned"

    local exit_code=0
    local output
    output=$(run_require_cosign_with "$TEST_TEMP_DIR/shadow:$TEST_TEMP_DIR/bin" "$pinned") ||
        exit_code=$?

    assert_equals "1" "$exit_code" \
        "require_cosign returns 1 when a substitute precedes the base cosign on PATH (#1029)"
    assert_contains "$output" "cosign resolved to $shadow, not the base install at $pinned" \
        "Error names the substitute that shadows the base install"
    assert_contains "$output" "COSIGN_BIN unset" \
        "COSIGN_BIN is not exported when the guard fails"
}

# Control for the shadow test: the same two stubs in the opposite PATH order
# pass, so the shadow test fails because of order, not because of the stubs.
test_path_order_base_first_returns_zero() {
    local pinned="$TEST_TEMP_DIR/bin/cosign"
    write_cosign_stub "$TEST_TEMP_DIR/shadow/cosign"
    write_cosign_stub "$pinned"

    local exit_code=0
    local output
    output=$(run_require_cosign_with "$TEST_TEMP_DIR/bin:$TEST_TEMP_DIR/shadow" "$pinned") ||
        exit_code=$?

    assert_equals "0" "$exit_code" \
        "require_cosign returns 0 when the base cosign comes first on PATH"
    assert_contains "$output" "COSIGN_BIN=$pinned" \
        "COSIGN_BIN is exported as the verified absolute path"
}

# A cosign shell function wins over every PATH entry, and `command -v` then
# prints the bare name. It must be rejected even with the base binary present.
test_shell_function_cosign_returns_one() {
    local pinned="$TEST_TEMP_DIR/bin/cosign"
    write_cosign_stub "$pinned"

    local exit_code=0
    local output
    output=$(run_require_cosign_with "$TEST_TEMP_DIR/bin" "$pinned" \
        "cosign() { echo impostor; }") || exit_code=$?

    assert_equals "1" "$exit_code" \
        "require_cosign returns 1 when cosign is a shell function (#1029)"
    assert_contains "$output" "cosign resolved to cosign, not the base install" \
        "Error names the function (bare name) as the resolution"
}

# A symlink at the pinned path passes the string comparison while running
# whatever it points at. Without the symlink check this returns 0.
test_symlink_at_pin_returns_one() {
    local pinned="$TEST_TEMP_DIR/bin/cosign"
    write_cosign_stub "$TEST_TEMP_DIR/elsewhere/cosign"
    command ln -s "$TEST_TEMP_DIR/elsewhere/cosign" "$pinned"

    local exit_code=0
    local output
    output=$(run_require_cosign_with "$TEST_TEMP_DIR/bin" "$pinned") || exit_code=$?

    assert_equals "1" "$exit_code" \
        "require_cosign returns 1 when the pinned path is a symlink (#1029)"
    assert_contains "$output" "cosign at $pinned is a symlink or not a regular file" \
        "Error names the symlinked pin"
    assert_contains "$output" "COSIGN_BIN unset" \
        "COSIGN_BIN is not exported for a symlinked pin"
}

# A COSIGN_BIN left over from an earlier call (or the environment) must not
# survive a failed check, or a caller that ignores the return code would still
# run it. Without the unset at the top of require_cosign this keeps the value.
test_failure_clears_stale_cosign_bin() {
    local pinned="$TEST_TEMP_DIR/bin/cosign"
    write_cosign_stub "$TEST_TEMP_DIR/shadow/cosign"
    write_cosign_stub "$pinned"

    local output
    output=$(run_require_cosign_with "$TEST_TEMP_DIR/shadow:$TEST_TEMP_DIR/bin" "$pinned" \
        "export COSIGN_BIN='$TEST_TEMP_DIR/shadow/cosign'") || true

    assert_contains "$output" "COSIGN_BIN unset" \
        "A pre-set COSIGN_BIN is cleared when require_cosign fails"
}

# The pin is assigned unconditionally at source time, so a _COSIGN_BASE_PATH
# exported by the build environment cannot redirect it to a substitute. With a
# ${_COSIGN_BASE_PATH:-...} default instead, this returns 0.
test_env_cannot_widen_pin() {
    local exit_code=0
    local output
    output=$(run_require_cosign "present" "" "$TEST_TEMP_DIR/bin/cosign") || exit_code=$?

    assert_equals "1" "$exit_code" \
        "An exported _COSIGN_BASE_PATH does not override the pin (#940)"
    assert_contains "$output" "not the base install at /usr/local/bin/cosign" \
        "The pin stays at setup.sh's install location"
}

# The pinned location is the literal path lib/base/setup.sh installs to. The
# first assertion is behavioral (the value the sourced helper actually holds).
# The second is only a source-text tripwire on setup.sh: it catches the install
# line moving away from /usr/local/bin/cosign, not every way it could drift.
test_pin_matches_setup_install_target() {
    local pinned
    pinned=$(bash -c "
        _COSIGN_REQUIRE_LOADED=''
        protected_export() { :; }
        source '$SOURCE_FILE'
        printf '%s' \"\$_COSIGN_BASE_PATH\"
    ")

    assert_equals "/usr/local/bin/cosign" "$pinned" \
        "require_cosign pins cosign to /usr/local/bin/cosign"
    assert_file_contains "$PROJECT_ROOT/lib/base/setup.sh" "chmod +x /usr/local/bin/cosign" \
        "lib/base/setup.sh installs cosign at the pinned location"
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
run_test_with_setup test_present_outside_base_returns_one "Present outside base: returns 1 (#940)"
run_test_with_setup test_env_cannot_widen_pin "Env cannot widen the path pin (#940)"
run_test_with_setup test_path_order_shadow_returns_one "PATH-order shadow: returns 1 (#1029)"
run_test_with_setup test_path_order_base_first_returns_zero "PATH order, base first: returns 0, exports COSIGN_BIN"
run_test_with_setup test_shell_function_cosign_returns_one "Shell-function cosign: returns 1 (#1029)"
run_test_with_setup test_symlink_at_pin_returns_one "Symlink at pin: returns 1 (#1029)"
run_test_with_setup test_failure_clears_stale_cosign_bin "Failure clears a stale COSIGN_BIN (#1029)"
run_test_with_setup test_pin_matches_setup_install_target "Pin matches setup.sh install target"
run_test_with_setup test_absent_returns_one "Absent: returns 1 with actionable error"
run_test_with_setup test_absent_does_not_create_cosign "Absent: installs nothing"

# Generate test report
generate_report
