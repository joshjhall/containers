#!/usr/bin/env bash
# Unit tests for bin/lib/keyring-swap.sh — the INT/TERM rollback trap of the
# swap_keyring_atomic transaction (#1443), split out of keyring-swap.sh (#1493)
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
test_suite "bin/lib/keyring-swap.sh (INT/TERM traps)"

# Shared gpg fixtures: require_gpg, make_empty_keybox (#1456)
# shellcheck source=tests/lib/gpg-keyring-fixtures.sh
source "$PROJECT_ROOT/tests/lib/gpg-keyring-fixtures.sh"

LIB_FILE="$PROJECT_ROOT/bin/lib/keyring-swap.sh"
GOOD_KEYRING="$PROJECT_ROOT/lib/gpg-keys/nodejs/keyring"

setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$TEST_SCRATCH_BASE/test-keyring-swap-signals-$unique_id"
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
# prints combined output, then a `traps=<...>` line naming any INT/TERM trap
# the helper left behind; returns the helper's (or the trap's exit) status.
# Any mv/cmp stubs exported by the caller apply inside the child.
run_swap() {
    # shellcheck disable=SC2016 # expands in the child shell
    bash -c '
        log_error() { printf "ERR: %s\n" "$1" >&2; }
        source "$1"
        swap_keyring_atomic "$2" "$3" "$4" "Test"
        rc=$?
        printf "traps=<%s>\n" "$(trap -p INT TERM)"
        exit "$rc"
    ' _ "$LIB_FILE" "$1" "$2" "$3" 2>&1
}

# leftovers <dest> — count keyring.new.*/keyring.old.* beside <dest>
leftovers() {
    command find "$(dirname "$1")" -mindepth 1 -maxdepth 1 -name "$(basename "$1").*" | command wc -l
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

# assert_signal <SIG> <window> <expected-rc> <new|previous> [keys-dir]
# keys-dir: parent of the keyring and work dir (see assert_signal_at_mktemp)
assert_signal() {
    local sig="$1" window="$2" expected_rc="$3" expect="$4" keys="${5:-$TEST_TEMP_DIR/keys}"
    make_src "$TEST_TEMP_DIR/src"
    local dest="$keys/keyring" work="$keys/work"
    make_dest "$dest"
    command mkdir -p "$work"
    printf 'x' >"$work/clone-marker"

    local output rc=0
    output=$(run_swap_signal "$TEST_TEMP_DIR/src" "$dest" "$work" "$sig" "$window") || rc=$?

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
    assert_dir_not_exists "$work" "work dir removed by the trap"
}

# run_swap_signal_at_mktemp <src> <dest> <work> <SIG> <pattern>
# Send <SIG> to the child from the mktemp whose template contains <pattern>,
# AFTER the real mktemp has created the dir and before the caller has
# assigned it — the pre-trap window of #1443.
run_swap_signal_at_mktemp() {
    (
        # shellcheck disable=SC2329 # invoked by the child via export -f
        mktemp() {
            command mktemp "$@" || return 1
            case "${!#}" in *"$SIG_PATTERN"*) kill -"$SIG_NAME" $$ ;; esac
        }
        export -f mktemp
        export SIG_NAME="$4" SIG_PATTERN="$5"
        run_swap "$1" "$2" "$3"
    )
}

# assert_signal_at_mktemp <SIG> <pattern> <expected-rc> [first-install] [keys-dir]
# The rc alone cannot discriminate (an untrapped INT/TERM also exits 130/143);
# the leftovers count and the removed work dir are what prove the trap ran.
# first-install: no keyring exists yet, so the trap's no-restore branch runs.
# keys-dir: parent of the keyring (and work dir); the trap expands its paths
# at fire time, so a name with a space and a `$` pins that quoting.
assert_signal_at_mktemp() {
    local sig="$1" pattern="$2" expected_rc="$3" mode="${4:-}" keys="${5:-$TEST_TEMP_DIR/keys}"
    make_src "$TEST_TEMP_DIR/src"
    local dest="$keys/keyring" work="$keys/work"
    command mkdir -p "$keys" "$work"
    [ "$mode" = first-install ] || make_dest "$dest"
    printf 'x' >"$work/clone-marker"

    local output rc=0
    output=$(run_swap_signal_at_mktemp "$TEST_TEMP_DIR/src" "$dest" "$work" "$sig" "$pattern") || rc=$?

    assert_equals "$expected_rc" "$rc" "$sig at the $pattern mktemp exits with the signal status (output: $output)"
    if [ "$mode" = first-install ]; then
        assert_dir_not_exists "$dest" "no keyring created after $sig at the $pattern mktemp"
    else
        assert_equals "previous-pubring" "$(command cat "$dest/pubring.kbx" 2>/dev/null)" \
            "existing keyring untouched after $sig at the $pattern mktemp"
    fi
    assert_equals "0" "$(leftovers "$dest")" "no keyring.new.*/keyring.old.* left after $sig at the $pattern mktemp"
    assert_dir_not_exists "$work" "work dir removed by the trap"
}

test_swap_term_at_staging_mktemp() {
    require_gpg || return 0
    assert_signal_at_mktemp TERM ".new." 143
}

test_swap_int_at_staging_mktemp() {
    require_gpg || return 0
    assert_signal_at_mktemp INT ".new." 130
}

test_swap_term_at_holder_mktemp() {
    require_gpg || return 0
    assert_signal_at_mktemp TERM ".old." 143
}

test_swap_int_at_holder_mktemp() {
    require_gpg || return 0
    assert_signal_at_mktemp INT ".old." 130
}

test_swap_term_at_holder_mktemp_first_install() {
    require_gpg || return 0
    assert_signal_at_mktemp TERM ".old." 143 first-install
}

test_swap_term_at_holder_mktemp_special_path() {
    require_gpg || return 0
    # shellcheck disable=SC2016 # a literal $ in the directory name
    assert_signal_at_mktemp TERM ".old." 143 "" "$TEST_TEMP_DIR/key s"'/$ring'
}

test_swap_term_at_staging_mktemp_first_install() {
    require_gpg || return 0
    assert_signal_at_mktemp TERM ".new." 143 first-install
}

# run_swap_signal_at_cleanup <src> <dest> <work> <SIG> <failure>
# Force a failure return, then send <SIG> from that return's own cleanup
# `rm -rf` of the staging dir, AFTER it runs: the trap still being installed
# at that point is what removes the holder dir and the work dir. A return
# that drops the trap before cleaning up exits by the default action instead,
# leaving both behind.
#   holder     - the holder-dir mktemp fails (only staging exists yet)
#   staged     - corrupt source, so the staged check fails
#   move-aside - the existing keyring cannot be moved aside
#   install    - the install rename fails (the keyring is restored first)
run_swap_signal_at_cleanup() {
    local failure="$5"
    (
        # shellcheck disable=SC2329 # invoked by the child via export -f
        rm() {
            local a hit=false
            for a in "$@"; do
                [[ "$a" == */keyring.new.* ]] && hit=true
            done
            command rm "$@"
            if [ "$hit" = true ] && [ ! -e "$SIG_FIRED" ]; then
                : >"$SIG_FIRED"
                kill -"$SIG_NAME" $$
            fi
        }
        # shellcheck disable=SC2329 # invoked by the child via export -f
        mv() {
            case "$SIG_FAILURE" in
                move-aside) [[ "${!#}" == */keyring.old.*/keyring ]] && return 1 ;;
                install) [[ "$1" == */keyring.new.* && "${!#}" == "$SIG_DEST" ]] && return 1 ;;
            esac
            command mv "$@"
        }
        # shellcheck disable=SC2329 # invoked by the child via export -f
        mktemp() {
            [[ "$SIG_FAILURE" == holder && "${!#}" == *.old.* ]] && return 1
            command mktemp "$@"
        }
        export -f rm mv mktemp
        export SIG_NAME="$4" SIG_FAILURE="$failure" SIG_DEST="$2" SIG_FIRED="$TEST_TEMP_DIR/sig-fired"
        run_swap "$1" "$2" "$3"
    )
}

# assert_signal_at_cleanup <SIG> <failure> <expected-rc>
# On a plain failure return the work dir is the caller's to remove, so its
# absence proves the trap ran; the fired marker proves the signal was sent.
assert_signal_at_cleanup() {
    local sig="$1" failure="$2" expected_rc="$3"
    if [ "$failure" = staged ]; then
        make_src "$TEST_TEMP_DIR/src" corrupt
    else
        make_src "$TEST_TEMP_DIR/src"
    fi
    local dest="$TEST_TEMP_DIR/keys/keyring"
    make_dest "$dest"
    command mkdir -p "$TEST_TEMP_DIR/work"
    printf 'x' >"$TEST_TEMP_DIR/work/clone-marker"

    local output rc=0
    output=$(run_swap_signal_at_cleanup "$TEST_TEMP_DIR/src" "$dest" "$TEST_TEMP_DIR/work" "$sig" "$failure") || rc=$?

    assert_file_exists "$TEST_TEMP_DIR/sig-fired" "the $failure cleanup reached its staging rm"
    assert_equals "$expected_rc" "$rc" "$sig during the $failure cleanup exits through its trap (output: $output)"
    assert_equals "previous-pubring" "$(command cat "$dest/pubring.kbx" 2>/dev/null)" \
        "existing keyring in place after $sig during the $failure cleanup"
    assert_equals "0" "$(leftovers "$dest")" "no keyring.new.*/keyring.old.* left after $sig during the $failure cleanup"
    assert_dir_not_exists "$TEST_TEMP_DIR/work" "work dir removed by the trap"
}

test_swap_term_during_holder_failure_cleanup() {
    require_gpg || return 0
    assert_signal_at_cleanup TERM holder 143
}

test_swap_term_during_staged_failure_cleanup() {
    require_gpg || return 0
    assert_signal_at_cleanup TERM staged 143
}

test_swap_term_during_move_aside_failure_cleanup() {
    require_gpg || return 0
    assert_signal_at_cleanup TERM move-aside 143
}

test_swap_int_during_install_failure_cleanup() {
    require_gpg || return 0
    assert_signal_at_cleanup INT install 130
}

# Send <SIG> from gpg while swap_keyring_atomic is inside count_keyring_keys:
# the trap then runs in count_keyring_keys's frame, so it reads the swap's
# locals only as long as count_keyring_keys declares none with those names.
test_swap_term_during_staged_validation() {
    require_gpg || return 0
    make_src "$TEST_TEMP_DIR/src"
    local dest="$TEST_TEMP_DIR/keys/keyring"
    make_dest "$dest"
    command mkdir -p "$TEST_TEMP_DIR/work"
    printf 'x' >"$TEST_TEMP_DIR/work/clone-marker"

    local output rc=0
    output=$(
        # shellcheck disable=SC2329 # invoked by the child via export -f
        gpg() {
            kill -TERM "$SWAP_PID"
            command gpg "$@"
        }
        export -f gpg
        # The stub runs inside count_keyring_keys's command substitution, so
        # it signals the child bash by its exported pid
        # shellcheck disable=SC2016 # expands in the child shell
        bash -c '
            export SWAP_PID=$$
            log_error() { printf "ERR: %s\n" "$1" >&2; }
            source "$1"
            swap_keyring_atomic "$2" "$3" "$4" "Test"
        ' _ "$LIB_FILE" "$TEST_TEMP_DIR/src" "$dest" "$TEST_TEMP_DIR/work" 2>&1
    ) || rc=$?

    assert_equals "143" "$rc" "TERM during validation exits through its trap (output: $output)"
    assert_equals "previous-pubring" "$(command cat "$dest/pubring.kbx" 2>/dev/null)" \
        "existing keyring untouched after TERM during validation"
    assert_equals "0" "$(leftovers "$dest")" "no keyring.new.*/keyring.old.* left after TERM during validation"
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

# The restore branch (mv the moved-aside keyring back) expands its paths at
# fire time too, and it is the one branch that can lose the keyring
test_swap_term_mid_swap_restores_special_path() {
    require_gpg || return 0
    # shellcheck disable=SC2016 # a literal $ in the directory name
    assert_signal TERM mid 143 previous "$TEST_TEMP_DIR/key s"'/$ring'
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

# The traps go in before either mktemp (#1443), so its failure returns must
# clear them too. The child reports its rc and the error line so each
# iteration proves it took its own failure branch, not the success path or
# the other mktemp's (both of which also leave no trap behind).
test_swap_mktemp_failure_clears_traps() {
    require_gpg || return 0
    make_src "$TEST_TEMP_DIR/src"
    command mkdir -p "$TEST_TEMP_DIR/work"
    local dest="$TEST_TEMP_DIR/keys/keyring"
    local pattern expected output
    for pattern in ".new." ".old."; do
        case "$pattern" in
            .new.) expected="Could not create a staging directory" ;;
            .old.) expected="Could not create a directory to move the existing keyring aside" ;;
        esac
        # The pattern goes in via the environment: inside the stub, $5
        # would be the stub's own (empty) 5th argument, matching every mktemp
        # shellcheck disable=SC2016 # expands in the child shell
        output=$(MKTEMP_FAIL="$pattern" bash -c '
            log_error() { printf "ERR: %s\n" "$1"; }
            mktemp() {
                case "${!#}" in *"$MKTEMP_FAIL"*) return 1 ;; esac
                command mktemp "$@"
            }
            source "$1"
            swap_keyring_atomic "$2" "$3" "$4" Test 2>&1
            printf "rc=%s\n" "$?"
            printf "traps=<%s>\n" "$(trap -p INT TERM)"
        ' _ "$LIB_FILE" "$TEST_TEMP_DIR/src" "$dest" "$TEST_TEMP_DIR/work")
        assert_contains "$output" "rc=1" "a failed $pattern mktemp returns 1 (output: $output)"
        assert_contains "$output" "ERR: $expected" "the $pattern iteration takes its own failure branch"
        assert_contains "$output" "traps=<>" "no INT/TERM trap outlives a failed $pattern mktemp"
        assert_equals "0" "$(leftovers "$dest")" "no keyring.new.*/keyring.old.* left after a failed $pattern mktemp"
    done
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
run_test_with_setup test_swap_term_at_staging_mktemp "swap: SIGTERM at the staging mktemp leaves nothing behind"
run_test_with_setup test_swap_int_at_staging_mktemp "swap: SIGINT at the staging mktemp leaves nothing behind"
run_test_with_setup test_swap_term_at_holder_mktemp "swap: SIGTERM at the holder mktemp leaves nothing behind"
run_test_with_setup test_swap_int_at_holder_mktemp "swap: SIGINT at the holder mktemp leaves nothing behind"
run_test_with_setup test_swap_term_at_holder_mktemp_first_install "swap: SIGTERM at the holder mktemp on first install leaves nothing behind"
run_test_with_setup test_swap_term_at_holder_mktemp_special_path "swap: SIGTERM at the holder mktemp cleans up a path with a space and \$"
run_test_with_setup test_swap_term_at_staging_mktemp_first_install "swap: SIGTERM at the staging mktemp on first install leaves nothing behind"
run_test_with_setup test_swap_term_during_holder_failure_cleanup "swap: SIGTERM during the holder-mktemp failure cleanup still runs the trap"
run_test_with_setup test_swap_term_during_staged_failure_cleanup "swap: SIGTERM during the staged-check failure cleanup still runs the trap"
run_test_with_setup test_swap_term_during_move_aside_failure_cleanup "swap: SIGTERM during the move-aside failure cleanup still runs the trap"
run_test_with_setup test_swap_int_during_install_failure_cleanup "swap: SIGINT during the install failure cleanup still runs the trap"
run_test_with_setup test_swap_term_during_staged_validation "swap: SIGTERM inside count_keyring_keys still cleans up through the swap trap"
run_test_with_setup test_swap_term_during_staging "swap: SIGTERM during staging keeps the existing keyring"
run_test_with_setup test_swap_int_during_staging "swap: SIGINT during staging keeps the existing keyring"
run_test_with_setup test_swap_term_mid_swap_restores "swap: SIGTERM mid-swap restores the existing keyring"
run_test_with_setup test_swap_int_mid_swap_restores "swap: SIGINT mid-swap restores the existing keyring"
run_test_with_setup test_swap_term_mid_swap_restores_special_path "swap: SIGTERM mid-swap restores a keyring whose path has a space and \$"
run_test_with_setup test_swap_term_post_swap_keeps_new "swap: SIGTERM post-swap keeps the new keyring"
run_test_with_setup test_swap_clears_traps_on_return "swap: INT/TERM traps cleared on return"
run_test_with_setup test_swap_mktemp_failure_clears_traps "swap: INT/TERM traps cleared on a mktemp failure return"

# Generate test report
generate_report
