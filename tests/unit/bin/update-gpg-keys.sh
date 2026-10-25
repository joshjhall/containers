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
KEYRING_SWAP_LIB="$PROJECT_ROOT/bin/lib/keyring-swap.sh"

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

# Test: Script sources the keyring stage/validate/swap helper (#1426)
test_gpg_sources_keyring_swap() {
    assert_file_contains "$SOURCE_FILE" 'source "$SCRIPT_DIR/lib/keyring-swap.sh"' \
        "Should source bin/lib/keyring-swap.sh"
    assert_file_contains "$SOURCE_FILE" 'swap_keyring_atomic "$temp_dir/release-keys/gpg"' \
        "update_nodejs_keys should swap via swap_keyring_atomic"
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

# make_empty_keybox <home> <kbx> — create a keybox holding no keys without
# relying on gpg's homedir defaults: an explicit empty common.conf keeps
# use-keyboxd off (GnuPG 2.4.1+ would otherwise write public-keys.d/ and no
# .kbx), and the keyring path is named rather than inferred (#1433)
make_empty_keybox() {
    command mkdir -p "$1"
    command chmod 700 "$1"
    : >"$1/common.conf"
    GNUPGHOME="$1" gpg --batch --no-default-keyring --keyring "$2" --list-keys >/dev/null 2>&1
    [ -f "$2" ]
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
# With STALE_OLD_PID_DIR=1, first plant the leftover a SIGKILLed run would
# leave at keyring.old.<pid> — under the script's OWN pid, by creating it and
# then exec-ing the script in the same process (#1436).
run_update() {
    if [ "${STALE_OLD_PID_DIR:-}" = "1" ]; then
        # shellcheck disable=SC2016 # $$ / $1 / $2 expand in the child shell
        NODEJS_RELEASE_KEYS_REPO="$1" GPG_KEYS_DIR="$2" bash -c '
            stale="$1/nodejs/keyring.old.$$"
            command mkdir -p "$stale" &&
                printf stale-pubring >"$stale/pubring.kbx" &&
                exec bash "$2" nodejs
        ' _ "$2" "$SOURCE_FILE" 2>&1
        return
    fi
    NODEJS_RELEASE_KEYS_REPO="$1" GPG_KEYS_DIR="$2" \
        bash "$SOURCE_FILE" nodejs 2>&1
}

# stale_old_pid_dir <keys_dir> — print the planted keyring.old.<pid> leftover
stale_old_pid_dir() {
    command grep -l 'stale-pubring' "$1"/nodejs/keyring.old.*/pubring.kbx 2>/dev/null |
        command head -n 1 | command xargs -r dirname
}

# Test: a readable upstream keyring is copied byte-for-byte and the script exits 0
test_gpg_nodejs_readable_keyring_succeeds() {
    require_gpg || return 0
    make_fixture_repo "$TEST_TEMP_DIR/repo"

    # Replace an existing keyring, as in production (one is always committed),
    # so the move-aside / swap / cleanup path is exercised on success too
    local dest="$TEST_TEMP_DIR/keys/nodejs/keyring"
    command mkdir -p "$dest"
    printf 'previous-pubring' >"$dest/pubring.kbx"
    printf 'previous-trustdb' >"$dest/trustdb.gpg"

    local output rc=0
    output=$(run_update "$TEST_TEMP_DIR/repo" "$TEST_TEMP_DIR/keys") || rc=$?

    assert_equals "0" "$rc" "update should succeed for a readable keyring (output: $output)"
    local f
    for f in pubring.kbx trustdb.gpg; do
        if command cmp -s "$COMMITTED_NODEJS_KEYRING/$f" "$dest/$f"; then
            assert_true true "written $f is byte-identical to the source"
        else
            assert_true false "written $f differs from the source (or is missing)"
        fi
    done
    local leftovers
    leftovers=$(command find "$TEST_TEMP_DIR/keys/nodejs" -mindepth 1 -maxdepth 1 -name 'keyring.*' | command wc -l)
    assert_equals "0" "$leftovers" "a successful swap leaves no keyring.new.*/keyring.old.* behind"
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
    if ! make_empty_keybox "$empty_home" "$empty_home/pubring.kbx"; then
        assert_true false "could not build an empty keybox fixture (is use-keyboxd set system-wide?)"
        return 0
    fi
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

# run_update_term_on_install <repo> <keys_dir> <tmpdir> <mid|post>
# Run the real script with an exported `mv` that sends SIGTERM to the script
# on the install rename (staging keyring.new.* -> keyring) (#1427):
#   mid  - signal BEFORE the rename: the existing keyring is already moved
#          aside, so the trap must put it back
#   post - signal AFTER the rename: the trap must only clean up
# An exported function, not a PATH stub: BASH_ENV rebuilds PATH in the child
# bash. $$ inside it is the script's own pid (mv runs in the script's shell).
# TMPDIR is pinned so the temp clone's location is known.
run_update_term_on_install() {
    (
        # shellcheck disable=SC2329 # invoked by the child script via export -f
        mv() {
            # shellcheck disable=SC2053 # glob match on purpose
            if [[ "$1" == */keyring.new.* && "${!#}" == $MV_TERM_DEST ]]; then
                if [ "$MV_TERM_WINDOW" = post ]; then
                    command mv "$@" || return 1
                fi
                kill -TERM $$
                return 1
            fi
            command mv "$@"
        }
        export -f mv
        export MV_TERM_DEST="$2/nodejs/keyring" MV_TERM_WINDOW="$4" TMPDIR="$3"
        run_update "$1" "$2"
    )
}

# assert_term_window <mid|post> — drive one SIGTERM window end-to-end
assert_term_window() {
    local window="$1"
    make_fixture_repo "$TEST_TEMP_DIR/repo"

    local dest="$TEST_TEMP_DIR/keys/nodejs/keyring"
    command mkdir -p "$dest" "$TEST_TEMP_DIR/tmp"
    printf 'previous-pubring' >"$dest/pubring.kbx"
    printf 'previous-trustdb' >"$dest/trustdb.gpg"

    local output rc=0
    output=$(run_update_term_on_install "$TEST_TEMP_DIR/repo" "$TEST_TEMP_DIR/keys" \
        "$TEST_TEMP_DIR/tmp" "$window") || rc=$?

    assert_equals "143" "$rc" "$window-swap SIGTERM exits through the TERM trap (output: $output)"
    if [ "$window" = mid ]; then
        assert_equals "previous-pubring" "$(command cat "$dest/pubring.kbx" 2>/dev/null)" \
            "previous pubring.kbx restored"
        assert_equals "previous-trustdb" "$(command cat "$dest/trustdb.gpg" 2>/dev/null)" \
            "previous trustdb.gpg restored"
    else
        if command cmp -s "$COMMITTED_NODEJS_KEYRING/pubring.kbx" "$dest/pubring.kbx"; then
            assert_true true "new pubring.kbx in place"
        else
            assert_true false "new pubring.kbx not in place after a post-swap SIGTERM"
        fi
    fi
    assert_false "[ -e '$dest/keyring' ]" "no keyring nested inside the keyring"
    local leftovers
    leftovers=$(command find "$TEST_TEMP_DIR/keys/nodejs" -mindepth 1 -maxdepth 1 -name 'keyring.*' | command wc -l)
    assert_equals "0" "$leftovers" "no keyring.new.*/keyring.old.* left after a $window-swap SIGTERM"
    local clones
    clones=$(command find "$TEST_TEMP_DIR/tmp" -name release-keys | command wc -l)
    assert_equals "0" "$clones" "temp clone removed after a $window-swap SIGTERM"
    if [ -e "$TEST_TEMP_DIR/keys/nodejs/keyring-metadata.json" ]; then
        assert_true false "metadata must not be written when the run is interrupted"
    fi
}

# Test: SIGTERM after the move-aside, before install, restores the previous keyring
test_gpg_nodejs_term_mid_swap_restores() {
    require_gpg || return 0
    assert_term_window mid
}

# Test: SIGTERM right after install keeps the new keyring and cleans up
test_gpg_nodejs_term_post_swap_cleans_up() {
    require_gpg || return 0
    assert_term_window post
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
    stranded=$(command find "$TEST_TEMP_DIR/keys/nodejs" -mindepth 2 -maxdepth 2 -path '*/keyring.old.*/keyring' | command head -n 1)
    assert_contains "$output" "the previous keyring is at $stranded;" \
        "the reported path is the moved-aside keyring"
    assert_equals "previous-pubring" "$(command cat "$stranded/pubring.kbx" 2>/dev/null)" \
        "the reported path holds the previous keyring"
}

# Test: a leftover keyring.old.<pid> under the script's own pid (a SIGKILLed
# earlier run) does not swallow the keyring on a successful update (#1436)
test_gpg_nodejs_stale_old_pid_dir_success() {
    require_gpg || return 0
    make_fixture_repo "$TEST_TEMP_DIR/repo"

    local dest="$TEST_TEMP_DIR/keys/nodejs/keyring"
    command mkdir -p "$dest"
    printf 'previous-pubring' >"$dest/pubring.kbx"

    local output rc=0
    output=$(STALE_OLD_PID_DIR=1 run_update "$TEST_TEMP_DIR/repo" "$TEST_TEMP_DIR/keys") || rc=$?

    assert_equals "0" "$rc" "update should succeed despite the leftover (output: $output)"
    if command cmp -s "$COMMITTED_NODEJS_KEYRING/pubring.kbx" "$dest/pubring.kbx"; then
        assert_true true "new pubring.kbx installed"
    else
        assert_true false "new pubring.kbx not installed"
    fi
    assert_false "[ -e '$dest/keyring' ]" "no keyring nested inside the keyring"
    local stale
    stale=$(stale_old_pid_dir "$TEST_TEMP_DIR/keys")
    assert_not_empty "$stale" "the leftover the script did not create is left alone"
    local nested
    nested=$(command find "$TEST_TEMP_DIR/keys/nodejs" -mindepth 2 -name keyring | command wc -l)
    assert_equals "0" "$nested" "no keyring nested anywhere under nodejs/"
}

# Test: with the same leftover, an install failure restores the REAL previous
# keyring — not the stale copy, and not nested at keyring/keyring (#1436)
test_gpg_nodejs_stale_old_pid_dir_install_failure() {
    require_gpg || return 0
    make_fixture_repo "$TEST_TEMP_DIR/repo"

    local dest="$TEST_TEMP_DIR/keys/nodejs/keyring"
    command mkdir -p "$dest"
    printf 'previous-pubring' >"$dest/pubring.kbx"

    local output rc=0
    output=$(STALE_OLD_PID_DIR=1 run_update_failing_mv "$TEST_TEMP_DIR/repo" "$TEST_TEMP_DIR/keys" "$dest" 1) || rc=$?

    assert_not_equals "0" "$rc" "update must exit non-zero when the new keyring cannot be installed"
    assert_contains "$output" "Could not install the new keyring" "should name the install failure"
    assert_equals "previous-pubring" "$(command cat "$dest/pubring.kbx" 2>/dev/null)" \
        "the real previous keyring is restored, not the stale leftover"
    assert_false "[ -e '$dest/keyring' ]" "no keyring nested inside the restored keyring"
    local stale
    stale=$(stale_old_pid_dir "$TEST_TEMP_DIR/keys")
    assert_not_empty "$stale" "the leftover the script did not create is left alone"
    local others
    others=$(command find "$TEST_TEMP_DIR/keys/nodejs" -mindepth 1 -maxdepth 1 -name 'keyring.*' ! -path "$stale" | command wc -l)
    assert_equals "0" "$others" "no keyring.new.*/keyring.old.* of this run left behind"
}

# assert_mktemp_guard <fail-pattern> <expected-message>
# Run the update with exactly ONE kind of mktemp failing, and assert it fails
# closed with that guard's own message, without running cp/chmod on an empty
# path (which would expand to `chmod 600 /*`).
#
# <fail-pattern> selects the mktemp that fails, by its last argument:
#   keyring-check.  - count_keyring_keys' scratch (first hit: the upstream check)
#   .new.           - the staging dir beside the keyring
#   .old.           - the holder dir the existing keyring is moved aside into
#   <plain>         - the template-less `mktemp -d` for update_nodejs_keys' temp_dir
# Every other mktemp runs for real, so each case reaches its own guard. Each
# guard is proven by removing it and watching its case fail.
#
# Safety: cp and chmod are exported tripwires that refuse — and record — any
# empty, `/`, or direct-child-of-`/` target, so a regressed guard cannot
# touch the root filesystem.
assert_mktemp_guard() {
    local fail_pattern="$1"
    local expected="$2"
    make_fixture_repo "$TEST_TEMP_DIR/repo"

    local dest="$TEST_TEMP_DIR/keys/nodejs/keyring"
    command mkdir -p "$dest"
    printf 'previous-pubring' >"$dest/pubring.kbx"

    local trip="$TEST_TEMP_DIR/tripwire.log"
    : >"$trip"
    local output rc=0
    # shellcheck disable=SC2329 # invoked by the child script via export -f
    output=$(
        mktemp() {
            local target="${!#}"
            if [ "$MKTEMP_FAIL" = "<plain>" ]; then
                # The template-less call is `mktemp -d` (last arg is the flag)
                [ "$target" = "-d" ] && return 1
            else
                case "$target" in *"$MKTEMP_FAIL"*) return 1 ;; esac
            fi
            command mktemp "$@"
        }
        # Trip on exactly the hazard an empty $scratch/$staging creates: an
        # empty target, `/` itself, or a direct child of `/` (`chmod 600 /*`
        # expands to /bin, /etc, ...). Anything deeper is allowed, so the
        # container's own shell-init chmods (BASH_ENV) are not mistaken for
        # the script's.
        guard_path() {
            local a
            for a in "$@"; do
                case "$a" in
                    -*) continue ;;
                    "" | / | /*/*) ;;
                    /*)
                        printf '%s\n' "$a" >>"$TRIPWIRE_LOG"
                        return 1
                        ;;
                    *) continue ;;
                esac
                if [ -z "$a" ] || [ "$a" = / ]; then
                    printf '<%s>\n' "${a:-empty}" >>"$TRIPWIRE_LOG"
                    return 1
                fi
            done
        }
        cp() {
            guard_path "$@" || return 1
            command cp "$@"
        }
        chmod() {
            guard_path "$@" || return 1
            command chmod "$@"
        }
        export -f mktemp guard_path cp chmod
        export TRIPWIRE_LOG="$trip" TEST_TEMP_DIR MKTEMP_FAIL="$fail_pattern"
        run_update "$TEST_TEMP_DIR/repo" "$TEST_TEMP_DIR/keys"
    ) || rc=$?

    assert_not_equals "0" "$rc" "update must exit non-zero when the $fail_pattern mktemp fails"
    assert_contains "$output" "$expected" "should name the $fail_pattern mktemp failure"
    assert_equals "" "$(command cat "$trip")" "no cp/chmod may target an empty, /, or top-level path"
    assert_equals "previous-pubring" "$(command cat "$dest/pubring.kbx")" "existing keyring untouched"
    local leftovers
    leftovers=$(command find "$TEST_TEMP_DIR/keys/nodejs" -mindepth 1 -maxdepth 1 -name 'keyring.*' | command wc -l)
    assert_equals "0" "$leftovers" "no keyring.new.*/keyring.old.* directories left behind"
}

test_gpg_nodejs_scratch_mktemp_failure_fails_closed() {
    require_gpg || return 0
    assert_mktemp_guard "keyring-check." "Could not create a scratch directory"
}

test_gpg_nodejs_staging_mktemp_failure_fails_closed() {
    require_gpg || return 0
    assert_mktemp_guard ".new." "Could not create a staging directory"
}

test_gpg_nodejs_previous_mktemp_failure_fails_closed() {
    require_gpg || return 0
    assert_mktemp_guard ".old." "Could not create a directory to move the existing keyring aside"
}

test_gpg_nodejs_tempdir_mktemp_failure_fails_closed() {
    require_gpg || return 0
    assert_mktemp_guard "<plain>" "Could not create a temporary directory"
}

# assert_tempdir_guard <lang> [fail|empty]
# Run the python/hashicorp/golang updater with its `mktemp -d` broken and
# assert it fails closed before any download (#1432). "fail" exits 1 (the
# `if !` half of the guard); "empty" exits 0 printing nothing (the
# `[ ! -d ]` half), so each half is pinned by its own case. With an empty
# $temp_dir, `curl -o "$temp_dir/x.asc"` writes /x.asc and the copy reads
# from /. curl is an exported stub that records every call and fails, so no
# network is used and a regressed guard shows up in the log, not just as a
# non-zero exit (a failing curl would produce that on its own).
assert_tempdir_guard() {
    local lang="$1"
    local mode="${2:-fail}"
    local curl_log="$TEST_TEMP_DIR/curl.log"
    : >"$curl_log"
    local output rc=0
    # shellcheck disable=SC2329 # invoked by the child script via export -f
    output=$(
        mktemp() {
            if [ "${!#}" = "-d" ]; then
                [ "$MKTEMP_MODE" = "empty" ] && return 0
                return 1
            fi
            command mktemp "$@"
        }
        curl() {
            printf '%s\n' "$*" >>"$CURL_LOG"
            return 1
        }
        export -f mktemp curl
        export CURL_LOG="$curl_log" MKTEMP_MODE="$mode"
        GPG_KEYS_DIR="$TEST_TEMP_DIR/keys" bash "$SOURCE_FILE" "$lang" 2>&1
    ) || rc=$?

    assert_not_equals "0" "$rc" "$lang update must exit non-zero when mktemp fails"
    assert_contains "$output" "Could not create a temporary directory" \
        "$lang should name the temp_dir mktemp failure"
    assert_equals "" "$(command cat "$curl_log")" "$lang must not download once mktemp fails"
    assert_dir_not_exists "$TEST_TEMP_DIR/keys/$lang/keys" "$lang keys dir must not be created"
}

test_gpg_python_tempdir_mktemp_failure_fails_closed() {
    assert_tempdir_guard python
}

test_gpg_hashicorp_tempdir_mktemp_failure_fails_closed() {
    assert_tempdir_guard hashicorp
}

test_gpg_golang_tempdir_mktemp_failure_fails_closed() {
    assert_tempdir_guard golang
}

test_gpg_python_tempdir_mktemp_empty_fails_closed() {
    assert_tempdir_guard python empty
}

test_gpg_hashicorp_tempdir_mktemp_empty_fails_closed() {
    assert_tempdir_guard hashicorp empty
}

test_gpg_golang_tempdir_mktemp_empty_fails_closed() {
    assert_tempdir_guard golang empty
}

# Test: every mktemp result is checked before use — main suspends set -e, so
# an unchecked failure leaves an empty path that resolves under / (#1432)
test_gpg_every_mktemp_checked() {
    local unchecked
    unchecked=$(command grep -n '\$(mktemp' "$SOURCE_FILE" "$KEYRING_SWAP_LIB" |
        command grep -vE 'if ! ([A-Za-z_]+)=\$\(mktemp [^)]*\) \|\| \[ ! -d "\$\1" \]' || true)
    assert_equals "" "$unchecked" "every \$(mktemp ...) must be guarded with 'if ! var=\$(mktemp ...) || [ ! -d \"\$var\" ]'"
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
run_test_with_setup test_gpg_sources_keyring_swap "Sources lib/keyring-swap.sh for the keyring swap"
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
run_test_with_setup test_gpg_nodejs_term_mid_swap_restores "Node.js: SIGTERM mid-swap restores the previous keyring (#1427)"
run_test_with_setup test_gpg_nodejs_term_post_swap_cleans_up "Node.js: SIGTERM post-swap keeps the new keyring and cleans up (#1427)"
run_test_with_setup test_gpg_nodejs_stale_old_pid_dir_success "Node.js: leftover keyring.old.<pid> does not swallow the keyring (#1436)"
run_test_with_setup test_gpg_nodejs_stale_old_pid_dir_install_failure "Node.js: leftover keyring.old.<pid> is not restored as the keyring (#1436)"
run_test_with_setup test_gpg_nodejs_scratch_mktemp_failure_fails_closed "Node.js: scratch mktemp failure fails closed"
run_test_with_setup test_gpg_nodejs_staging_mktemp_failure_fails_closed "Node.js: staging mktemp failure fails closed"
run_test_with_setup test_gpg_nodejs_previous_mktemp_failure_fails_closed "Node.js: move-aside holder mktemp failure fails closed"
run_test_with_setup test_gpg_nodejs_tempdir_mktemp_failure_fails_closed "Node.js: temp_dir mktemp failure fails closed"
run_test_with_setup test_gpg_python_tempdir_mktemp_failure_fails_closed "Python: temp_dir mktemp failure fails closed"
run_test_with_setup test_gpg_hashicorp_tempdir_mktemp_failure_fails_closed "HashiCorp: temp_dir mktemp failure fails closed"
run_test_with_setup test_gpg_golang_tempdir_mktemp_failure_fails_closed "Go: temp_dir mktemp failure fails closed"
run_test_with_setup test_gpg_python_tempdir_mktemp_empty_fails_closed "Python: empty mktemp output fails closed"
run_test_with_setup test_gpg_hashicorp_tempdir_mktemp_empty_fails_closed "HashiCorp: empty mktemp output fails closed"
run_test_with_setup test_gpg_golang_tempdir_mktemp_empty_fails_closed "Go: empty mktemp output fails closed"
run_test_with_setup test_gpg_every_mktemp_checked "Every mktemp result is checked"
run_test_with_setup test_gpg_nodejs_dropped_trustdb_not_left_stale "Node.js: dropped upstream trustdb.gpg is not left stale"

# Generate test report
generate_report
