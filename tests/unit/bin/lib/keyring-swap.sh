#!/usr/bin/env bash
# Unit tests for bin/lib/keyring-swap.sh — count_keyring_keys and the
# swap_keyring_atomic stage/validate/swap transaction (#1426)
#
# Each swap runs in a child bash (run_swap) so the helper's INT/TERM traps
# and `exit` never touch this suite. Keyrings are built from the committed
# Node.js keyring; nothing outside $TEST_TEMP_DIR is written.

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "bin/lib/keyring-swap.sh"

LIB_FILE="$PROJECT_ROOT/bin/lib/keyring-swap.sh"
GOOD_KEYRING="$PROJECT_ROOT/lib/gpg-keys/nodejs/keyring"

setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$TEST_SCRATCH_BASE/test-keyring-swap-$unique_id"
    command mkdir -p "$TEST_TEMP_DIR"
}

teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
    unset TEST_TEMP_DIR 2>/dev/null || true
}

run_test_with_setup() {
    setup
    run_test "$1" "$2"
    teardown
}

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

# make_src <dir> [corrupt|no-trustdb] — a source keyring dir from the good one.
# "corrupt" appends one newline to pubring.kbx (the #1410 damage).
make_src() {
    command mkdir -p "$1"
    command cp "$GOOD_KEYRING/pubring.kbx" "$GOOD_KEYRING/trustdb.gpg" "$1/"
    case "${2:-}" in
        corrupt) printf '\n' >>"$1/pubring.kbx" ;;
        no-trustdb) command rm -f "$1/trustdb.gpg" ;;
    esac
}

# make_dest <dir> — an existing keyring with sentinel bytes
make_dest() {
    command mkdir -p "$1"
    printf 'previous-pubring' >"$1/pubring.kbx"
    printf 'previous-trustdb' >"$1/trustdb.gpg"
}

# run_swap <src> <dest> <work> — source the lib in a child bash and swap;
# prints combined output, returns the helper's (or the trap's exit) status.
# Any mv/cmp stubs exported by the caller apply inside the child.
run_swap() {
    # shellcheck disable=SC2016 # expands in the child shell
    bash -c '
        log_error() { printf "ERR: %s\n" "$1" >&2; }
        source "$1"
        swap_keyring_atomic "$2" "$3" "$4" "Test"
    ' _ "$LIB_FILE" "$1" "$2" "$3" 2>&1
}

# leftovers <dest> — count keyring.new.*/keyring.old.* beside <dest>
leftovers() {
    command find "$(dirname "$1")" -mindepth 1 -maxdepth 1 -name "$(basename "$1").*" | command wc -l
}

# ---------------------------------------------------------------------------
# count_keyring_keys
# ---------------------------------------------------------------------------

# count_in_child <dir> — run count_keyring_keys in a child bash
count_in_child() {
    # shellcheck disable=SC2016 # expands in the child shell
    bash -c '
        log_error() { printf "ERR: %s\n" "$1" >&2; }
        source "$1"
        count_keyring_keys "$2"
    ' _ "$LIB_FILE" "$1"
}

test_count_good_keyring() {
    require_gpg || return 0
    make_src "$TEST_TEMP_DIR/src"
    local before after count rc=0
    before=$(command ls -A "$TEST_TEMP_DIR/src" | command sort | command tr '\n' ' ')
    count=$(count_in_child "$TEST_TEMP_DIR/src" 2>/dev/null) || rc=$?
    after=$(command ls -A "$TEST_TEMP_DIR/src" | command sort | command tr '\n' ' ')

    assert_equals "0" "$rc" "count succeeds on a readable keyring"
    if [[ "$count" =~ ^[1-9][0-9]*$ ]]; then
        assert_true true "count is a positive integer ($count)"
    else
        assert_true false "count is not a positive integer: '$count'"
    fi
    assert_equals "$before" "$after" "gpg wrote nothing into the source dir"
    if command cmp -s "$GOOD_KEYRING/pubring.kbx" "$TEST_TEMP_DIR/src/pubring.kbx"; then
        assert_true true "source pubring.kbx unchanged"
    else
        assert_true false "source pubring.kbx was modified"
    fi
}

test_count_corrupt_keyring_fails() {
    require_gpg || return 0
    make_src "$TEST_TEMP_DIR/src" corrupt
    local output rc=0
    output=$(count_in_child "$TEST_TEMP_DIR/src" 2>&1) || rc=$?
    assert_equals "1" "$rc" "count fails on a corrupt keyring"
    assert_contains "$output" "gpg cannot read keyring" "names the unreadable keyring"
}

test_count_missing_pubring_fails() {
    command mkdir -p "$TEST_TEMP_DIR/src" "$TEST_TEMP_DIR/scratch-parent"
    local rc=0
    # shellcheck disable=SC2016 # expands in the child shell
    bash -c '
        log_error() { :; }
        source "$1"
        count_keyring_keys "$2" "$3"
    ' _ "$LIB_FILE" "$TEST_TEMP_DIR/src" "$TEST_TEMP_DIR/scratch-parent" >/dev/null 2>&1 || rc=$?
    assert_equals "1" "$rc" "count fails when the keyring has no pubring.kbx"
    assert_equals "0" "$(command find "$TEST_TEMP_DIR/scratch-parent" -mindepth 1 | command wc -l)" \
        "no keyring-check.* scratch dir left behind"
}

test_count_empty_keyring_fails() {
    require_gpg || return 0
    local home="$TEST_TEMP_DIR/empty-home"
    command mkdir -p "$home" "$TEST_TEMP_DIR/src"
    command chmod 700 "$home"
    GNUPGHOME="$home" gpg --batch --list-keys >/dev/null 2>&1
    command cp "$home/pubring.kbx" "$TEST_TEMP_DIR/src/"
    local output rc=0
    output=$(count_in_child "$TEST_TEMP_DIR/src" 2>&1) || rc=$?
    assert_equals "1" "$rc" "count fails on a keyring with no keys"
    assert_contains "$output" "contains no public keys" "names the empty keyring"
}

# ---------------------------------------------------------------------------
# swap_keyring_atomic: completed transactions
# ---------------------------------------------------------------------------

test_swap_replaces_existing() {
    require_gpg || return 0
    make_src "$TEST_TEMP_DIR/src"
    local dest="$TEST_TEMP_DIR/keys/keyring"
    make_dest "$dest"
    command mkdir -p "$TEST_TEMP_DIR/work"

    local output rc=0
    output=$(run_swap "$TEST_TEMP_DIR/src" "$dest" "$TEST_TEMP_DIR/work") || rc=$?

    assert_equals "0" "$rc" "swap succeeds (output: $output)"
    local f
    for f in pubring.kbx trustdb.gpg; do
        if command cmp -s "$GOOD_KEYRING/$f" "$dest/$f"; then
            assert_true true "$f byte-identical to the source"
        else
            assert_true false "$f differs from the source (or is missing)"
        fi
    done
    assert_equals "0" "$(leftovers "$dest")" "no keyring.new.*/keyring.old.* left"
    assert_dir_exists "$TEST_TEMP_DIR/work" "work dir left for the caller on success"
}

test_swap_first_install() {
    require_gpg || return 0
    make_src "$TEST_TEMP_DIR/src"
    local dest="$TEST_TEMP_DIR/keys/nested/keyring"
    command mkdir -p "$TEST_TEMP_DIR/work"

    local output rc=0
    output=$(run_swap "$TEST_TEMP_DIR/src" "$dest" "$TEST_TEMP_DIR/work") || rc=$?

    assert_equals "0" "$rc" "swap succeeds with no existing keyring (output: $output)"
    if command cmp -s "$GOOD_KEYRING/pubring.kbx" "$dest/pubring.kbx"; then
        assert_true true "pubring.kbx installed"
    else
        assert_true false "pubring.kbx not installed"
    fi
    assert_equals "0" "$(leftovers "$dest")" "no keyring.new.*/keyring.old.* left"
}

test_swap_mirrors_source_without_trustdb() {
    require_gpg || return 0
    make_src "$TEST_TEMP_DIR/src" no-trustdb
    local dest="$TEST_TEMP_DIR/keys/keyring"
    make_dest "$dest"
    command mkdir -p "$TEST_TEMP_DIR/work"

    local rc=0
    run_swap "$TEST_TEMP_DIR/src" "$dest" "$TEST_TEMP_DIR/work" >/dev/null || rc=$?

    assert_equals "0" "$rc" "swap succeeds without a source trustdb.gpg"
    assert_file_not_exists "$dest/trustdb.gpg" "previous trustdb.gpg not left beside the new pubring.kbx"
}

# ---------------------------------------------------------------------------
# swap_keyring_atomic: failures keep (or restore) the existing keyring
# ---------------------------------------------------------------------------

test_swap_unreadable_source_keeps_existing() {
    require_gpg || return 0
    make_src "$TEST_TEMP_DIR/src" corrupt
    local dest="$TEST_TEMP_DIR/keys/keyring"
    make_dest "$dest"
    command mkdir -p "$TEST_TEMP_DIR/work"

    local output rc=0
    output=$(run_swap "$TEST_TEMP_DIR/src" "$dest" "$TEST_TEMP_DIR/work") || rc=$?

    assert_equals "1" "$rc" "swap returns 1 for an unreadable source"
    assert_contains "$output" "Staged Test keyring does not match upstream or is unreadable" \
        "the label names the keyring in the error"
    assert_equals "previous-pubring" "$(command cat "$dest/pubring.kbx")" "existing keyring untouched"
    assert_equals "0" "$(leftovers "$dest")" "no keyring.new.*/keyring.old.* left"
    assert_dir_exists "$TEST_TEMP_DIR/work" "work dir left for the caller on failure"
}

# run_swap_failing_mv <src> <dest> <work> <times> — fail the first <times> mv
# calls onto <dest>; every other mv runs for real
run_swap_failing_mv() {
    local counter="$TEST_TEMP_DIR/mv-fail-count"
    printf '%s' "$4" >"$counter"
    (
        # shellcheck disable=SC2329 # invoked by the child via export -f
        mv() {
            local left
            if [ "${!#}" = "$MV_FAIL_DEST" ]; then
                left=$(command cat "$MV_FAIL_COUNTER")
                if [ "$left" -gt 0 ]; then
                    printf '%s' "$((left - 1))" >"$MV_FAIL_COUNTER"
                    return 1
                fi
            fi
            command mv "$@"
        }
        export -f mv
        export MV_FAIL_DEST="$2" MV_FAIL_COUNTER="$counter"
        run_swap "$1" "$2" "$3"
    )
}

test_swap_install_failure_restores() {
    require_gpg || return 0
    make_src "$TEST_TEMP_DIR/src"
    local dest="$TEST_TEMP_DIR/keys/keyring"
    make_dest "$dest"
    command mkdir -p "$TEST_TEMP_DIR/work"

    local output rc=0
    output=$(run_swap_failing_mv "$TEST_TEMP_DIR/src" "$dest" "$TEST_TEMP_DIR/work" 1) || rc=$?

    assert_equals "1" "$rc" "swap returns 1 when the install rename fails"
    assert_contains "$output" "Could not install the new keyring" "names the install failure"
    assert_equals "previous-pubring" "$(command cat "$dest/pubring.kbx")" "previous keyring restored"
    assert_equals "0" "$(leftovers "$dest")" "no keyring.new.*/keyring.old.* left"
}

test_swap_move_aside_failure_keeps_existing() {
    require_gpg || return 0
    make_src "$TEST_TEMP_DIR/src"
    local dest="$TEST_TEMP_DIR/keys/keyring"
    make_dest "$dest"
    command mkdir -p "$TEST_TEMP_DIR/work"

    local output rc=0
    # shellcheck disable=SC2329 # invoked by the child via export -f
    output=$(
        mv() {
            # shellcheck disable=SC2053 # glob match on purpose
            [[ "${!#}" == */keyring.old.*/keyring ]] && return 1
            command mv "$@"
        }
        export -f mv
        run_swap "$TEST_TEMP_DIR/src" "$dest" "$TEST_TEMP_DIR/work"
    ) || rc=$?

    assert_equals "1" "$rc" "swap returns 1 when the existing keyring cannot be moved aside"
    assert_contains "$output" "Could not move the existing keyring aside" "names the move-aside failure"
    assert_equals "previous-pubring" "$(command cat "$dest/pubring.kbx")" "existing keyring untouched"
    assert_equals "0" "$(leftovers "$dest")" "no keyring.new.*/keyring.old.* left"
}

# assert_swap_mktemp_guard <pattern> <expected-message>
# Fail exactly the mktemp whose template contains <pattern>; every other
# mktemp runs for real. cp/chmod refuse (and record) an empty, `/`, or
# top-level target, so a regressed guard cannot touch the root filesystem.
assert_swap_mktemp_guard() {
    local pattern="$1" expected="$2"
    make_src "$TEST_TEMP_DIR/src"
    local dest="$TEST_TEMP_DIR/keys/keyring"
    make_dest "$dest"
    command mkdir -p "$TEST_TEMP_DIR/work"
    local trip="$TEST_TEMP_DIR/tripwire.log"
    : >"$trip"

    local output rc=0
    # shellcheck disable=SC2329 # invoked by the child via export -f
    output=$(
        mktemp() {
            case "${!#}" in *"$MKTEMP_FAIL"*) return 1 ;; esac
            command mktemp "$@"
        }
        guard_path() {
            local a
            for a in "$@"; do
                case "$a" in
                    -*) ;;
                    "" | /)
                        printf '<%s>\n' "${a:-empty}" >>"$TRIPWIRE_LOG"
                        return 1
                        ;;
                    /*/*) ;;
                    /*)
                        printf '%s\n' "$a" >>"$TRIPWIRE_LOG"
                        return 1
                        ;;
                esac
            done
        }
        cp() { guard_path "$@" && command cp "$@"; }
        chmod() { guard_path "$@" && command chmod "$@"; }
        export -f mktemp guard_path cp chmod
        export MKTEMP_FAIL="$pattern" TRIPWIRE_LOG="$trip"
        run_swap "$TEST_TEMP_DIR/src" "$dest" "$TEST_TEMP_DIR/work"
    ) || rc=$?

    assert_equals "1" "$rc" "swap returns 1 when the $pattern mktemp fails"
    assert_contains "$output" "$expected" "names the $pattern mktemp failure"
    assert_equals "" "$(command cat "$trip")" "no cp/chmod may target an empty, /, or top-level path"
    assert_equals "previous-pubring" "$(command cat "$dest/pubring.kbx")" "existing keyring untouched"
    assert_equals "0" "$(leftovers "$dest")" "no keyring.new.*/keyring.old.* left"
}

test_swap_staging_mktemp_failure() {
    require_gpg || return 0
    assert_swap_mktemp_guard ".new." "Could not create a staging directory"
}

test_swap_holder_mktemp_failure() {
    require_gpg || return 0
    assert_swap_mktemp_guard ".old." "Could not create a directory to move the existing keyring aside"
}

test_swap_scratch_mktemp_failure() {
    require_gpg || return 0
    assert_swap_mktemp_guard "keyring-check." "Could not create a scratch directory"
}

test_swap_failed_restore_reports_stranded() {
    require_gpg || return 0
    make_src "$TEST_TEMP_DIR/src"
    local dest="$TEST_TEMP_DIR/keys/keyring"
    make_dest "$dest"
    command mkdir -p "$TEST_TEMP_DIR/work"

    local output rc=0
    output=$(run_swap_failing_mv "$TEST_TEMP_DIR/src" "$dest" "$TEST_TEMP_DIR/work" 2) || rc=$?

    assert_equals "1" "$rc" "swap returns 1 when install and restore both fail"
    local stranded
    stranded=$(command find "$TEST_TEMP_DIR/keys" -mindepth 2 -maxdepth 2 -path '*/keyring.old.*/keyring' | command head -n 1)
    assert_not_empty "$stranded" "the moved-aside keyring is kept"
    assert_contains "$output" "the previous keyring is at $stranded;" "reports the stranded path"
    assert_equals "previous-pubring" "$(command cat "$stranded/pubring.kbx" 2>/dev/null)" \
        "the stranded path holds the previous keyring"
}

# ---------------------------------------------------------------------------
# swap_keyring_atomic: INT/TERM rollback trap
# ---------------------------------------------------------------------------

# run_swap_signal <src> <dest> <work> <SIG> <stage|mid|post>
# Send <SIG> to the child from inside the transaction:
#   stage - from cmp during staging (nothing moved yet)
#   mid   - from mv on the install rename, BEFORE it runs (existing moved aside)
#   post  - from mv on the install rename, AFTER it runs
run_swap_signal() {
    (
        # shellcheck disable=SC2329 # invoked by the child via export -f
        cmp() {
            [ "$SIG_WINDOW" = stage ] && kill -"$SIG_NAME" $$
            command cmp "$@"
        }
        # shellcheck disable=SC2329 # invoked by the child via export -f
        mv() {
            if [[ "$1" == */keyring.new.* && "${!#}" == "$SIG_DEST" ]]; then
                case "$SIG_WINDOW" in
                    mid)
                        kill -"$SIG_NAME" $$
                        return 1
                        ;;
                    post)
                        command mv "$@" || return 1
                        kill -"$SIG_NAME" $$
                        return 0
                        ;;
                esac
            fi
            command mv "$@"
        }
        export -f cmp mv
        export SIG_DEST="$2" SIG_NAME="$4" SIG_WINDOW="$5"
        run_swap "$1" "$2" "$3"
    )
}

# assert_signal <SIG> <window> <expected-rc> <new|previous>
assert_signal() {
    local sig="$1" window="$2" expected_rc="$3" expect="$4"
    make_src "$TEST_TEMP_DIR/src"
    local dest="$TEST_TEMP_DIR/keys/keyring"
    make_dest "$dest"
    command mkdir -p "$TEST_TEMP_DIR/work"
    printf 'x' >"$TEST_TEMP_DIR/work/clone-marker"

    local output rc=0
    output=$(run_swap_signal "$TEST_TEMP_DIR/src" "$dest" "$TEST_TEMP_DIR/work" "$sig" "$window") || rc=$?

    assert_equals "$expected_rc" "$rc" "$sig in the $window window exits through its trap (output: $output)"
    if [ "$expect" = previous ]; then
        assert_equals "previous-pubring" "$(command cat "$dest/pubring.kbx" 2>/dev/null)" \
            "previous keyring in place after $sig ($window)"
    elif command cmp -s "$GOOD_KEYRING/pubring.kbx" "$dest/pubring.kbx"; then
        assert_true true "new keyring in place after $sig ($window)"
    else
        assert_true false "new keyring not in place after $sig ($window)"
    fi
    assert_false "[ -e '$dest/keyring' ]" "no keyring nested inside the keyring"
    assert_equals "0" "$(leftovers "$dest")" "no keyring.new.*/keyring.old.* left after $sig ($window)"
    assert_dir_not_exists "$TEST_TEMP_DIR/work" "work dir removed by the trap"
}

test_swap_term_during_staging() {
    require_gpg || return 0
    assert_signal TERM stage 143 previous
}

test_swap_int_during_staging() {
    require_gpg || return 0
    assert_signal INT stage 130 previous
}

test_swap_term_mid_swap_restores() {
    require_gpg || return 0
    assert_signal TERM mid 143 previous
}

test_swap_int_mid_swap_restores() {
    require_gpg || return 0
    assert_signal INT mid 130 previous
}

test_swap_term_post_swap_keeps_new() {
    require_gpg || return 0
    assert_signal TERM post 143 new
}

test_swap_clears_traps_on_return() {
    require_gpg || return 0
    make_src "$TEST_TEMP_DIR/src"
    command mkdir -p "$TEST_TEMP_DIR/work"
    local traps
    # shellcheck disable=SC2016 # expands in the child shell
    traps=$(bash -c '
        log_error() { :; }
        source "$1"
        swap_keyring_atomic "$2" "$3" "$4" Test >/dev/null 2>&1
        trap -p INT TERM
    ' _ "$LIB_FILE" "$TEST_TEMP_DIR/src" "$TEST_TEMP_DIR/keys/keyring" "$TEST_TEMP_DIR/work")
    assert_equals "" "$traps" "no INT/TERM trap outlives a completed swap"
}

# ---------------------------------------------------------------------------
# Static checks
# ---------------------------------------------------------------------------

# A sourced lib's `set -e` leaks into its caller
test_lib_sets_no_shell_options() {
    local found
    found=$(command grep -nE '^[[:space:]]*set -[a-z]*[eu]' "$LIB_FILE" || true)
    assert_equals "" "$found" "keyring-swap.sh must not set shell options"
}

test_lib_syntax() {
    if bash -n "$LIB_FILE" 2>/dev/null; then
        assert_true true "keyring-swap.sh has valid bash syntax"
    else
        assert_true false "keyring-swap.sh has a syntax error"
    fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
run_test_with_setup test_count_good_keyring "count_keyring_keys: counts a readable keyring without writing to it"
run_test_with_setup test_count_corrupt_keyring_fails "count_keyring_keys: corrupt keyring fails"
run_test_with_setup test_count_missing_pubring_fails "count_keyring_keys: missing pubring.kbx fails and leaves no scratch"
run_test_with_setup test_count_empty_keyring_fails "count_keyring_keys: keyring with no keys fails"
run_test_with_setup test_swap_replaces_existing "swap: replaces an existing keyring byte-exact"
run_test_with_setup test_swap_first_install "swap: installs where no keyring exists yet"
run_test_with_setup test_swap_mirrors_source_without_trustdb "swap: no stale trustdb.gpg when the source ships none"
run_test_with_setup test_swap_unreadable_source_keeps_existing "swap: unreadable source keeps the existing keyring"
run_test_with_setup test_swap_install_failure_restores "swap: install failure restores the existing keyring"
run_test_with_setup test_swap_move_aside_failure_keeps_existing "swap: move-aside failure keeps the existing keyring"
run_test_with_setup test_swap_staging_mktemp_failure "swap: staging mktemp failure fails closed"
run_test_with_setup test_swap_holder_mktemp_failure "swap: move-aside holder mktemp failure fails closed"
run_test_with_setup test_swap_scratch_mktemp_failure "swap: count scratch mktemp failure fails closed"
run_test_with_setup test_swap_failed_restore_reports_stranded "swap: failed restore reports the stranded path"
run_test_with_setup test_swap_term_during_staging "swap: SIGTERM during staging keeps the existing keyring"
run_test_with_setup test_swap_int_during_staging "swap: SIGINT during staging keeps the existing keyring"
run_test_with_setup test_swap_term_mid_swap_restores "swap: SIGTERM mid-swap restores the existing keyring"
run_test_with_setup test_swap_int_mid_swap_restores "swap: SIGINT mid-swap restores the existing keyring"
run_test_with_setup test_swap_term_post_swap_keeps_new "swap: SIGTERM post-swap keeps the new keyring"
run_test_with_setup test_swap_clears_traps_on_return "swap: INT/TERM traps cleared on return"
run_test_with_setup test_lib_sets_no_shell_options "keyring-swap.sh sets no shell options"
run_test_with_setup test_lib_syntax "keyring-swap.sh has valid bash syntax"

# Generate test report
generate_report
