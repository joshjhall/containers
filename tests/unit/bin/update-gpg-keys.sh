#!/usr/bin/env bash
# Unit tests for bin/update-gpg-keys.sh
# Tests GPG key update script structure and content via static analysis

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Bin Update GPG Keys Tests"

SOURCE_FILE="$PROJECT_ROOT/bin/update-gpg-keys.sh"

# Setup function - runs before each test
setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$TEST_SCRATCH_BASE/test-update-gpg-keys-$unique_id"
    mkdir -p "$TEST_TEMP_DIR"
}

# Teardown function - runs after each test
teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
    unset TEST_TEMP_DIR 2>/dev/null || true
}

# Wrapper for running tests with setup/teardown
run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"

    setup
    run_test "$test_function" "$test_description"
    teardown
}

# ---------------------------------------------------------------------------
# Static analysis tests: Script structure
# ---------------------------------------------------------------------------

# Test: Script uses strict mode
test_gpg_strict_mode() {
    assert_file_contains "$SOURCE_FILE" "set -euo pipefail" \
        "update-gpg-keys.sh should use strict mode"
}

# Test: Script defines update_python_keys function
test_gpg_defines_update_python_keys() {
    assert_file_contains "$SOURCE_FILE" "update_python_keys()" \
        "Should define update_python_keys function"
}

# Test: Script defines update_nodejs_keys function
test_gpg_defines_update_nodejs_keys() {
    assert_file_contains "$SOURCE_FILE" "update_nodejs_keys()" \
        "Should define update_nodejs_keys function"
}

# Test: Script defines update_hashicorp_keys function
test_gpg_defines_update_hashicorp_keys() {
    assert_file_contains "$SOURCE_FILE" "update_hashicorp_keys()" \
        "Should define update_hashicorp_keys function"
}

# Test: Script defines update_golang_keys function
test_gpg_defines_update_golang_keys() {
    assert_file_contains "$SOURCE_FILE" "update_golang_keys()" \
        "Should define update_golang_keys function"
}

# Test: Script defines main function
test_gpg_defines_main() {
    assert_file_contains "$SOURCE_FILE" "main()" \
        "Should define main function"
}

# ---------------------------------------------------------------------------
# Static analysis tests: Logging functions
# ---------------------------------------------------------------------------

# Test: Script defines log_info function
test_gpg_defines_log_info() {
    assert_file_contains "$SOURCE_FILE" "log_info()" \
        "Should define log_info function"
}

# Test: Script defines log_success function
test_gpg_defines_log_success() {
    assert_file_contains "$SOURCE_FILE" "log_success()" \
        "Should define log_success function"
}

# Test: Script defines log_warning function
test_gpg_defines_log_warning() {
    assert_file_contains "$SOURCE_FILE" "log_warning()" \
        "Should define log_warning function"
}

# Test: Script defines log_error function
test_gpg_defines_log_error() {
    assert_file_contains "$SOURCE_FILE" "log_error()" \
        "Should define log_error function"
}

# ---------------------------------------------------------------------------
# Static analysis tests: Key paths and constants
# ---------------------------------------------------------------------------

# Test: GPG_KEYS_DIR references lib/gpg-keys
test_gpg_keys_dir_path() {
    assert_file_contains "$SOURCE_FILE" "lib/gpg-keys" \
        "GPG_KEYS_DIR should reference lib/gpg-keys"
}

# Test: HashiCorp fingerprint constant
test_gpg_hashicorp_fingerprint() {
    assert_file_contains "$SOURCE_FILE" "C874011F0AB405110D02105534365D9472D7468F" \
        "Should contain HashiCorp expected fingerprint"
}

# Test: Golang fingerprint constant
test_gpg_golang_fingerprint() {
    assert_file_contains "$SOURCE_FILE" "EB4C1BFD4F042F6DDDCCEC917721F63BD38B4796" \
        "Should contain Golang expected fingerprint"
}

# ---------------------------------------------------------------------------
# Static analysis tests: Key source URLs
# ---------------------------------------------------------------------------

# Test: Python key URL for Thomas Wouters
test_gpg_python_url_wouters() {
    assert_file_contains "$SOURCE_FILE" "github.com/Yhg1s.gpg" \
        "Should fetch Thomas Wouters GPG key from GitHub"
}

# Test: Python key URL for Pablo Galindo
test_gpg_python_url_galindo() {
    assert_file_contains "$SOURCE_FILE" "keybase.io/pablogsal" \
        "Should fetch Pablo Galindo GPG key from Keybase"
}

# Test: Python key URL for Lukasz Langa
test_gpg_python_url_langa() {
    assert_file_contains "$SOURCE_FILE" "keybase.io/ambv" \
        "Should fetch Lukasz Langa GPG key from Keybase"
}

# Test: Node.js uses release-keys repository
test_gpg_nodejs_release_keys_repo() {
    assert_file_contains "$SOURCE_FILE" "release-keys" \
        "Should use nodejs release-keys repository"
}

# Test: HashiCorp key URL
test_gpg_hashicorp_key_url() {
    assert_file_contains "$SOURCE_FILE" "hashicorp.com/.well-known/pgp-key.txt" \
        "Should fetch HashiCorp key from official well-known URL"
}

# Test: Golang key URL
test_gpg_golang_key_url() {
    assert_file_contains "$SOURCE_FILE" "dl.google.com/linux/linux_signing_key.pub" \
        "Should fetch Google Linux signing key"
}

# ---------------------------------------------------------------------------
# Static analysis tests: Security and file handling
# ---------------------------------------------------------------------------

# Test: Handles 'all' keyword
test_gpg_handles_all_keyword() {
    assert_file_contains "$SOURCE_FILE" '"all"' \
        "Should handle 'all' keyword to update all languages"
}

# Test: Handles unknown language with warning
test_gpg_handles_unknown_language() {
    assert_file_contains "$SOURCE_FILE" "Unknown language" \
        "Should warn about unknown languages"
}

# Test: Uses chmod 700 for key directories
test_gpg_chmod_700_directories() {
    assert_file_contains "$SOURCE_FILE" "chmod 700" \
        "Should set key directories to chmod 700"
}

# Test: Uses chmod 600 for key files
test_gpg_chmod_600_files() {
    assert_file_contains "$SOURCE_FILE" "chmod 600" \
        "Should set key files to chmod 600"
}

# Test: Uses mktemp -d for temporary directories
test_gpg_uses_mktemp() {
    assert_file_contains "$SOURCE_FILE" "mktemp -d" \
        "Should use mktemp -d for secure temporary directories"
}

# ---------------------------------------------------------------------------
# Functional tests with mock commands
# ---------------------------------------------------------------------------

# Test: main() defaults to all languages when no arguments
test_gpg_main_defaults_to_all() {
    # Verify the default behavior in the script logic
    local script_content
    script_content=$(command cat "$SOURCE_FILE")

    # Check for the logic that sets all languages when no args
    assert_contains "$script_content" 'languages=("python" "nodejs" "hashicorp" "golang")' \
        "main should default to all languages when no args given"
}

# Test: Script has valid bash syntax
test_gpg_script_syntax() {
    if bash -n "$SOURCE_FILE" 2>/dev/null; then
        assert_true true "Script has valid bash syntax"
    else
        local errors
        errors=$(bash -n "$SOURCE_FILE" 2>&1 || true)
        echo "Bash syntax errors found:" >&2
        echo "$errors" >&2
        assert_true false "Script contains bash syntax errors"
    fi
}

# ---------------------------------------------------------------------------
# Behavioral tests: update_nodejs_keys validates the keyring (#1410)
#
# The script is run for real against a local fixture "release-keys" repo
# (NODEJS_RELEASE_KEYS_REPO) and a scratch GPG_KEYS_DIR, so no network is used
# and the committed keyring is never touched.
# ---------------------------------------------------------------------------

COMMITTED_NODEJS_KEYRING="$PROJECT_ROOT/lib/gpg-keys/nodejs/keyring"

# Returns 0 when gpg is usable; otherwise skips locally and fails in CI, so a
# missing gpg can never make these tests pass by skipping.
require_gpg() {
    if command -v gpg >/dev/null 2>&1; then
        return 0
    fi
    if [ "${CI:-false}" = "true" ]; then
        assert_true false "gpg is required in CI — keyring tests cannot silently skip"
    else
        skip_test "gpg not available — skipping locally"
    fi
    return 1
}

# make_fixture_repo <dir> [corrupt|no-trustdb]
# Build a one-commit git repo shaped like nodejs/release-keys from the
# committed keyring. With "corrupt", append one newline to pubring.kbx — the
# exact damage auto-patch's trailing-newline fixer did (#1410). With
# "no-trustdb", upstream ships only pubring.kbx.
make_fixture_repo() {
    local repo="$1"
    local mode="${2:-}"
    command mkdir -p "$repo/gpg" "$repo/gpg-only-active-keys"
    command cp "$COMMITTED_NODEJS_KEYRING/pubring.kbx" "$COMMITTED_NODEJS_KEYRING/trustdb.gpg" "$repo/gpg/"
    command cp "$COMMITTED_NODEJS_KEYRING/pubring.kbx" "$COMMITTED_NODEJS_KEYRING/trustdb.gpg" "$repo/gpg-only-active-keys/"
    if [ "$mode" = "corrupt" ]; then
        printf '\n' >>"$repo/gpg/pubring.kbx"
    elif [ "$mode" = "no-trustdb" ]; then
        command rm -f "$repo/gpg/trustdb.gpg"
    fi
    git -C "$repo" init -q
    git -C "$repo" add -A
    git -C "$repo" -c user.name=test -c user.email=test@example.com \
        -c commit.gpgsign=false commit -q -m "fixture keyring"
}

# run_update <repo> <keys_dir> — run the real script for nodejs; prints combined output
run_update() {
    NODEJS_RELEASE_KEYS_REPO="$1" GPG_KEYS_DIR="$2" \
        bash "$SOURCE_FILE" nodejs 2>&1
}

# Test: a readable upstream keyring is copied byte-for-byte and the script exits 0
test_gpg_nodejs_readable_keyring_succeeds() {
    require_gpg || return 0
    make_fixture_repo "$TEST_TEMP_DIR/repo"

    local output rc=0
    output=$(run_update "$TEST_TEMP_DIR/repo" "$TEST_TEMP_DIR/keys") || rc=$?

    assert_equals "0" "$rc" "update should succeed for a readable keyring (output: $output)"
    if command cmp -s "$COMMITTED_NODEJS_KEYRING/pubring.kbx" "$TEST_TEMP_DIR/keys/nodejs/keyring/pubring.kbx"; then
        assert_true true "written pubring.kbx is byte-identical to the source"
    else
        assert_true false "written pubring.kbx differs from the source"
    fi
    assert_contains "$output" "Total keys in keyring: " "should report the key count"
}

# Test: an unreadable upstream keyring fails the script and keeps the old keyring
test_gpg_nodejs_unreadable_keyring_fails_closed() {
    require_gpg || return 0
    make_fixture_repo "$TEST_TEMP_DIR/repo" corrupt

    # Pre-existing (good) keyring that must survive the failed update
    local dest="$TEST_TEMP_DIR/keys/nodejs/keyring"
    command mkdir -p "$dest"
    command cp "$COMMITTED_NODEJS_KEYRING/pubring.kbx" "$COMMITTED_NODEJS_KEYRING/trustdb.gpg" "$dest/"

    local output rc=0
    output=$(run_update "$TEST_TEMP_DIR/repo" "$TEST_TEMP_DIR/keys") || rc=$?

    assert_not_equals "0" "$rc" "update must exit non-zero for an unreadable keyring"
    assert_contains "$output" "Upstream Node.js keyring is unreadable" \
        "should name the unreadable keyring as the failure"
    if command cmp -s "$COMMITTED_NODEJS_KEYRING/pubring.kbx" "$dest/pubring.kbx"; then
        assert_true true "existing keyring left untouched"
    else
        assert_true false "existing keyring was overwritten by an unreadable one"
    fi
    if [ -e "$TEST_TEMP_DIR/keys/nodejs/keyring-metadata.json" ]; then
        assert_true false "metadata must not be written when the keyring is rejected"
    fi
}

# Test: if the staged copy fails its check, the existing keyring is untouched.
# A readable upstream passes the upstream check; a `cmp` function that always
# reports a mismatch forces the staged-copy branch.
test_gpg_nodejs_staged_copy_failure_keeps_existing() {
    require_gpg || return 0
    make_fixture_repo "$TEST_TEMP_DIR/repo"

    # Existing keyring: distinct sentinel bytes so "untouched" is unambiguous
    local dest="$TEST_TEMP_DIR/keys/nodejs/keyring"
    command mkdir -p "$dest"
    printf 'previous-pubring' >"$dest/pubring.kbx"
    printf 'previous-trustdb' >"$dest/trustdb.gpg"

    # An exported function, not a PATH stub: BASH_ENV rebuilds PATH in the
    # child bash, so a PATH-prepended stub would be bypassed
    local output rc=0
    # shellcheck disable=SC2329 # invoked by the child script via export -f
    output=$(
        cmp() { return 1; }
        export -f cmp
        run_update "$TEST_TEMP_DIR/repo" "$TEST_TEMP_DIR/keys"
    ) || rc=$?

    assert_not_equals "0" "$rc" "update must exit non-zero when the staged keyring fails its check"
    assert_contains "$output" "Staged Node.js keyring does not match upstream" \
        "should report the staged-copy failure, not the upstream one"
    assert_equals "previous-pubring" "$(command cat "$dest/pubring.kbx")" "pubring.kbx untouched"
    assert_equals "previous-trustdb" "$(command cat "$dest/trustdb.gpg")" "trustdb.gpg untouched"
    if [ -e "$TEST_TEMP_DIR/keys/nodejs/keyring-metadata.json" ]; then
        assert_true false "metadata must not be written when the staged keyring is rejected"
    fi
    # No staging or swap directories may be left beside the keyring
    local leftovers
    leftovers=$(command find "$TEST_TEMP_DIR/keys/nodejs" -mindepth 1 -maxdepth 1 -name 'keyring.*' | command wc -l)
    assert_equals "0" "$leftovers" "no keyring.new.*/keyring.old.* directories left behind"
}

# Test: an upstream keyring gpg reads cleanly but that holds no keys is rejected
test_gpg_nodejs_empty_keyring_rejected() {
    require_gpg || return 0
    make_fixture_repo "$TEST_TEMP_DIR/repo"

    # Replace the fixture's keyring with an empty keybox gpg creates itself
    local empty_home="$TEST_TEMP_DIR/empty-home"
    command mkdir -p "$empty_home"
    command chmod 700 "$empty_home"
    GNUPGHOME="$empty_home" gpg --batch --list-keys >/dev/null 2>&1
    command cp "$empty_home/pubring.kbx" "$TEST_TEMP_DIR/repo/gpg/pubring.kbx"
    git -C "$TEST_TEMP_DIR/repo" -c user.name=test -c user.email=test@example.com \
        -c commit.gpgsign=false commit -q -am "empty keyring"

    local output rc=0
    output=$(run_update "$TEST_TEMP_DIR/repo" "$TEST_TEMP_DIR/keys") || rc=$?

    assert_not_equals "0" "$rc" "update must exit non-zero for a keyring with no keys"
    assert_contains "$output" "contains no public keys" "should name the empty keyring as the failure"
}

# run_update_failing_mv <repo> <keys_dir> <dest-glob> [times]
# Run the update with an exported `mv` that fails the first <times> (default 1)
# calls whose destination matches <dest-glob>; every other mv runs for real.
# The count lives in a file because each mv call is a function in the same
# child shell, but the counter must survive across calls reliably.
run_update_failing_mv() {
    local counter="$TEST_TEMP_DIR/mv-fail-count"
    printf '%s' "${4:-1}" >"$counter"
    (
        # shellcheck disable=SC2329 # invoked by the child script via export -f
        mv() {
            local left
            # shellcheck disable=SC2053 # glob match on purpose
            if [[ "${!#}" == $MV_FAIL_GLOB ]]; then
                left=$(command cat "$MV_FAIL_COUNTER")
                if [ "$left" -gt 0 ]; then
                    printf '%s' "$((left - 1))" >"$MV_FAIL_COUNTER"
                    return 1
                fi
            fi
            command mv "$@"
        }
        export -f mv
        export MV_FAIL_GLOB="$3" MV_FAIL_COUNTER="$counter"
        run_update "$1" "$2"
    )
}

# Test: if the existing keyring cannot be moved aside, it is kept as-is
test_gpg_nodejs_move_aside_failure_keeps_existing() {
    require_gpg || return 0
    make_fixture_repo "$TEST_TEMP_DIR/repo"

    local dest="$TEST_TEMP_DIR/keys/nodejs/keyring"
    command mkdir -p "$dest"
    printf 'previous-pubring' >"$dest/pubring.kbx"

    local output rc=0
    output=$(run_update_failing_mv "$TEST_TEMP_DIR/repo" "$TEST_TEMP_DIR/keys" '*/keyring.old.*') || rc=$?

    assert_not_equals "0" "$rc" "update must exit non-zero when the keyring cannot be moved aside"
    assert_contains "$output" "Could not move the existing keyring aside" "should name the move-aside failure"
    assert_equals "previous-pubring" "$(command cat "$dest/pubring.kbx")" "existing keyring untouched"
    local leftovers
    leftovers=$(command find "$TEST_TEMP_DIR/keys/nodejs" -mindepth 1 -maxdepth 1 -name 'keyring.*' | command wc -l)
    assert_equals "0" "$leftovers" "no keyring.new.*/keyring.old.* directories left behind"
}

# Test: if installing the staged keyring fails, the moved-aside keyring is put back
test_gpg_nodejs_install_failure_restores_existing() {
    require_gpg || return 0
    make_fixture_repo "$TEST_TEMP_DIR/repo"

    local dest="$TEST_TEMP_DIR/keys/nodejs/keyring"
    command mkdir -p "$dest"
    printf 'previous-pubring' >"$dest/pubring.kbx"

    # Fail only the first rename onto .../keyring (staging -> keyring); the
    # restore that follows targets the same path and must succeed
    local output rc=0
    output=$(run_update_failing_mv "$TEST_TEMP_DIR/repo" "$TEST_TEMP_DIR/keys" "$dest" 1) || rc=$?

    assert_not_equals "0" "$rc" "update must exit non-zero when the new keyring cannot be installed"
    assert_contains "$output" "Could not install the new keyring" "should name the install failure"
    assert_equals "previous-pubring" "$(command cat "$dest/pubring.kbx")" "previous keyring restored"
    local leftovers
    leftovers=$(command find "$TEST_TEMP_DIR/keys/nodejs" -mindepth 1 -maxdepth 1 -name 'keyring.*' | command wc -l)
    assert_equals "0" "$leftovers" "no keyring.new.*/keyring.old.* directories left behind"
}

# Test: if both the install and the restore fail, the stranded keyring's path
# is reported rather than claiming a restore that did not happen
test_gpg_nodejs_failed_restore_reports_stranded_keyring() {
    require_gpg || return 0
    make_fixture_repo "$TEST_TEMP_DIR/repo"

    local dest="$TEST_TEMP_DIR/keys/nodejs/keyring"
    command mkdir -p "$dest"
    printf 'previous-pubring' >"$dest/pubring.kbx"

    local output rc=0
    output=$(run_update_failing_mv "$TEST_TEMP_DIR/repo" "$TEST_TEMP_DIR/keys" "$dest" 2) || rc=$?

    assert_not_equals "0" "$rc" "update must exit non-zero"
    assert_contains "$output" "Restore failed — the previous keyring is at" \
        "should report where the stranded keyring is"
    local stranded
    stranded=$(command find "$TEST_TEMP_DIR/keys/nodejs" -mindepth 1 -maxdepth 1 -name 'keyring.old.*' | command head -n 1)
    assert_equals "previous-pubring" "$(command cat "$stranded/pubring.kbx" 2>/dev/null)" \
        "the reported path holds the previous keyring"
}

# Test: when upstream drops trustdb.gpg, the previous one does not linger
# beside the new pubring.kbx
test_gpg_nodejs_dropped_trustdb_not_left_stale() {
    require_gpg || return 0
    make_fixture_repo "$TEST_TEMP_DIR/repo" no-trustdb

    local dest="$TEST_TEMP_DIR/keys/nodejs/keyring"
    command mkdir -p "$dest"
    command cp "$COMMITTED_NODEJS_KEYRING/pubring.kbx" "$COMMITTED_NODEJS_KEYRING/trustdb.gpg" "$dest/"

    local output rc=0
    output=$(run_update "$TEST_TEMP_DIR/repo" "$TEST_TEMP_DIR/keys") || rc=$?

    assert_equals "0" "$rc" "update should succeed without an upstream trustdb.gpg (output: $output)"
    if [ -e "$dest/trustdb.gpg" ]; then
        assert_true false "stale trustdb.gpg left beside the new pubring.kbx"
    else
        assert_true true "previous trustdb.gpg removed when upstream ships none"
    fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
run_test_with_setup test_gpg_strict_mode "Script uses set -euo pipefail"
run_test_with_setup test_gpg_defines_update_python_keys "Defines update_python_keys function"
run_test_with_setup test_gpg_defines_update_nodejs_keys "Defines update_nodejs_keys function"
run_test_with_setup test_gpg_defines_update_hashicorp_keys "Defines update_hashicorp_keys function"
run_test_with_setup test_gpg_defines_update_golang_keys "Defines update_golang_keys function"
run_test_with_setup test_gpg_defines_main "Defines main function"
run_test_with_setup test_gpg_defines_log_info "Defines log_info function"
run_test_with_setup test_gpg_defines_log_success "Defines log_success function"
run_test_with_setup test_gpg_defines_log_warning "Defines log_warning function"
run_test_with_setup test_gpg_defines_log_error "Defines log_error function"
run_test_with_setup test_gpg_keys_dir_path "GPG_KEYS_DIR references lib/gpg-keys"
run_test_with_setup test_gpg_hashicorp_fingerprint "HashiCorp fingerprint constant present"
run_test_with_setup test_gpg_golang_fingerprint "Golang fingerprint constant present"
run_test_with_setup test_gpg_python_url_wouters "Python key URL for Thomas Wouters"
run_test_with_setup test_gpg_python_url_galindo "Python key URL for Pablo Galindo"
run_test_with_setup test_gpg_python_url_langa "Python key URL for Lukasz Langa"
run_test_with_setup test_gpg_nodejs_release_keys_repo "Node.js uses release-keys repository"
run_test_with_setup test_gpg_hashicorp_key_url "HashiCorp key URL is correct"
run_test_with_setup test_gpg_golang_key_url "Golang key URL is correct"
run_test_with_setup test_gpg_handles_all_keyword "Handles 'all' keyword"
run_test_with_setup test_gpg_handles_unknown_language "Handles unknown language with warning"
run_test_with_setup test_gpg_chmod_700_directories "Uses chmod 700 for key directories"
run_test_with_setup test_gpg_chmod_600_files "Uses chmod 600 for key files"
run_test_with_setup test_gpg_uses_mktemp "Uses mktemp -d for temporary directories"
run_test_with_setup test_gpg_main_defaults_to_all "main() defaults to all languages when no args"
run_test_with_setup test_gpg_script_syntax "Script has valid bash syntax"
run_test_with_setup test_gpg_nodejs_readable_keyring_succeeds "Node.js: readable keyring is copied byte-exact"
run_test_with_setup test_gpg_nodejs_unreadable_keyring_fails_closed "Node.js: unreadable keyring fails closed"
run_test_with_setup test_gpg_nodejs_staged_copy_failure_keeps_existing "Node.js: staged-copy check failure keeps existing keyring"
run_test_with_setup test_gpg_nodejs_empty_keyring_rejected "Node.js: keyring with no keys is rejected"
run_test_with_setup test_gpg_nodejs_move_aside_failure_keeps_existing "Node.js: move-aside failure keeps existing keyring"
run_test_with_setup test_gpg_nodejs_install_failure_restores_existing "Node.js: install failure restores existing keyring"
run_test_with_setup test_gpg_nodejs_failed_restore_reports_stranded_keyring "Node.js: failed restore reports the stranded keyring path"
run_test_with_setup test_gpg_nodejs_dropped_trustdb_not_left_stale "Node.js: dropped upstream trustdb.gpg is not left stale"

# Generate test report
generate_report
