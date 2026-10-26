#!/usr/bin/env bash
# Unit tests for bin/enforce-command-prefix.sh: the write path
# Tests how a fixed file is written back — mode keeping, unwritable
# directories, atomic replace, signal and failure cleanup, symlink operands.
# Split from tests/unit/bin/enforce-command-prefix.sh (#1490).

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Bin Enforce Command Prefix Write-Path Tests"

SCRIPT="$PROJECT_ROOT/bin/enforce-command-prefix.sh"

# Helper: write test fixture data to a file without triggering the hook.
# Uses a heredoc so the hook's heredoc exclusion protects the content.
write_fixture() {
    local file="$1"
    shift
    # Write each argument as a line
    for line in "$@"; do
        printf '%s\n' "$line"
    done >"$file"
}

# Helper: octal permission bits of a file, GNU (stat -c) or BSD (stat -f).
# Prints nothing (and still returns 0) if neither form works. Bare 'stat'
# (not 'command stat') so an exported stat() stub can stand in for a BSD
# userland.
file_mode() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || true
}

# Setup function - runs before each test
setup() {
    export TEST_TEMP_DIR
    TEST_TEMP_DIR=$(/usr/bin/mktemp -d -t "enforce-prefix-test-XXXXXX")
}

# Teardown function - runs after each test
teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ] && [ -d "$TEST_TEMP_DIR" ]; then
        /usr/bin/rm -rf "$TEST_TEMP_DIR"
    fi
    unset TEST_TEMP_DIR
}

# Test: file_mode falls back to BSD 'stat -f %Lp' and prints nothing (rc 0)
# when neither form works. Each stub lives in a subshell so it can't leak.
test_file_mode_fallbacks() {
    local f="$TEST_TEMP_DIR/m.sh"
    : >"$f"
    local bsd
    bsd=$(
        stat() {
            [ "$1" = "-f" ] && [ "$2" = "%Lp" ] && [ "$3" = "$f" ] || return 1
            printf '640\n'
        }
        file_mode "$f"
    )
    assert_equals "640" "$bsd" "BSD stat -f %Lp is used when -c is rejected"
    local none rc=0
    none=$(
        stat() { return 1; }
        file_mode "$f"
    ) || rc=$?
    assert_equals "0" "$rc" "file_mode returns 0 when no stat form works"
    assert_equals "" "$none" "file_mode prints nothing when no stat form works"
}

# Test: a rewritten file keeps its mode (the tmpfile is created 0600)
test_fixed_file_keeps_mode() {
    write_fixture "$TEST_TEMP_DIR/test.sh" 'grep x' # enforce-command-prefix: off
    chmod 755 "$TEST_TEMP_DIR/test.sh"
    local exit_code=0
    "$SCRIPT" "$TEST_TEMP_DIR/test.sh" >/dev/null || exit_code=$?
    assert_equals "1" "$exit_code" "Should exit 1 when changes made"
    # Exit 1 means the hook read the mode, so file_mode can too (#1439)
    assert_equals "755" "$(file_mode "$TEST_TEMP_DIR/test.sh")" "Fixed file should keep its 755 mode"
}

# Helper: run the hook on test.sh ('grep x', mode $3 or 644) with a PATH
# stub named $2 whose body is $1; sets exit_code and err (stderr). BASH_ENV
# is cleared so /etc/bash_env can't rebuild PATH and drop the stub.
run_with_stub() {
    /usr/bin/mkdir -p "$TEST_TEMP_DIR/stub"
    printf '#!/bin/sh\n%s\n' "$1" >"$TEST_TEMP_DIR/stub/$2"
    /bin/chmod 755 "$TEST_TEMP_DIR/stub/$2"
    /usr/bin/rm -f "$TEST_TEMP_DIR/test.sh"         # a prior call may have left it read-only
    write_fixture "$TEST_TEMP_DIR/test.sh" 'grep x' # enforce-command-prefix: off
    /bin/chmod "${3:-644}" "$TEST_TEMP_DIR/test.sh"
    exit_code=0
    err=$(env -u BASH_ENV PATH="$TEST_TEMP_DIR/stub:$PATH" \
        "$SCRIPT" "$TEST_TEMP_DIR/test.sh" 2>&1 >/dev/null) || exit_code=$?
}

# Test: mode survives a BSD-style chmod that rejects GNU --reference (#1429)
test_fixed_file_keeps_mode_without_gnu_chmod() {
    local exit_code err
    run_with_stub 'case "$1" in --reference*) exit 1 ;; esac
exec /bin/chmod "$@"' chmod 755
    assert_equals "1" "$exit_code" "Should exit 1 when changes made"
    assert_equals "command grep x" "$(command cat "$TEST_TEMP_DIR/test.sh")" \
        "Fixed content should be written back"
    assert_equals "" "$(/usr/bin/find "$TEST_TEMP_DIR" -name '*.enforce.*')" \
        "No tmpfile should be left after a successful write"
    # Exit 1 means the hook read the mode, so file_mode can too (#1439)
    assert_equals "755" "$(file_mode "$TEST_TEMP_DIR/test.sh")" "Fixed file should keep 755 without GNU chmod --reference"
}

# Test: a read-only file in a writable directory is fixed by the rename and
# stays read-only (#1440)
test_readonly_file_fixed_keeps_mode() {
    local exit_code mode
    for mode in 555 444; do
        /usr/bin/rm -f "$TEST_TEMP_DIR/test.sh"
        write_fixture "$TEST_TEMP_DIR/test.sh" 'grep x' # enforce-command-prefix: off
        chmod "$mode" "$TEST_TEMP_DIR/test.sh"
        exit_code=0
        "$SCRIPT" "$TEST_TEMP_DIR/test.sh" >/dev/null 2>&1 || exit_code=$?
        assert_equals "1" "$exit_code" "Mode-$mode file should be fixed (exit 1)"
        assert_equals "command grep x" "$(command cat "$TEST_TEMP_DIR/test.sh")" \
            "Mode-$mode file should hold the fixed content"
        assert_equals "$mode" "$(file_mode "$TEST_TEMP_DIR/test.sh")" \
            "Fixed file should keep its $mode mode"
        assert_equals "" "$(/usr/bin/find "$TEST_TEMP_DIR" -name '*.enforce.*')" \
            "No tmpfile should be left"
    done
    chmod 644 "$TEST_TEMP_DIR/test.sh"
}

# Test: a fixable file in an unwritable directory → exit 2 (not mktemp's 1,
# which would read as "fixed"), named on stderr, original unchanged
test_unwritable_dir_exits_2() {
    if [ "$(id -u)" -eq 0 ]; then
        skip_test "root can create files in a mode-555 directory"
        return
    fi
    /usr/bin/mkdir -p "$TEST_TEMP_DIR/ro"
    write_fixture "$TEST_TEMP_DIR/ro/test.sh" 'grep x' # enforce-command-prefix: off
    chmod 555 "$TEST_TEMP_DIR/ro"
    local exit_code=0 err
    err=$("$SCRIPT" "$TEST_TEMP_DIR/ro/test.sh" 2>&1 >/dev/null) || exit_code=$?
    chmod 755 "$TEST_TEMP_DIR/ro"
    assert_equals "2" "$exit_code" "Unwritable directory should exit 2, not 0 or 1"
    assert_contains "$err" "could not create a tmpfile beside $TEST_TEMP_DIR/ro/test.sh" \
        "Stderr should name the file"
    assert_equals "grep x" "$(command cat "$TEST_TEMP_DIR/ro/test.sh")" \
        "Original should be unchanged"
}

# Test: a clean file in an unwritable directory → exit 0, silent, no tmpfile:
# nothing needs writing, so the directory's mode must not matter (#1484)
test_unwritable_dir_clean_exits_0() {
    if [ "$(id -u)" -eq 0 ]; then
        skip_test "root can create files in a mode-555 directory"
        return
    fi
    /usr/bin/mkdir -p "$TEST_TEMP_DIR/ro"
    write_fixture "$TEST_TEMP_DIR/ro/test.sh" 'command grep x'
    chmod 555 "$TEST_TEMP_DIR/ro"
    local exit_code=0 out
    out=$("$SCRIPT" "$TEST_TEMP_DIR/ro/test.sh" 2>&1) || exit_code=$?
    chmod 755 "$TEST_TEMP_DIR/ro"
    assert_equals "0" "$exit_code" "Clean file in an unwritable directory should exit 0"
    assert_equals "" "$out" "Clean file should produce no output"
    assert_equals "command grep x" "$(command cat "$TEST_TEMP_DIR/ro/test.sh")" \
        "Clean file should be unchanged"
    assert_equals "" "$(/usr/bin/find "$TEST_TEMP_DIR" -name '*.enforce.*')" \
        "No tmpfile should be left"
}

# Test: a symlinked operand is skipped — the link survives and its target,
# which may lie outside the repo, is never rewritten (#1439) — and the run
# goes on to fix the regular file after it
test_symlink_operand_skipped() {
    /usr/bin/mkdir -p "$TEST_TEMP_DIR/outside" "$TEST_TEMP_DIR/repo"
    write_fixture "$TEST_TEMP_DIR/outside/target.sh" 'grep x' # enforce-command-prefix: off
    write_fixture "$TEST_TEMP_DIR/repo/plain.sh" 'grep x'     # enforce-command-prefix: off
    /usr/bin/ln -s ../outside/target.sh "$TEST_TEMP_DIR/repo/link.sh"
    local exit_code=0 out
    out=$("$SCRIPT" "$TEST_TEMP_DIR/repo/link.sh" "$TEST_TEMP_DIR/repo/plain.sh") || exit_code=$?
    assert_equals "1" "$exit_code" "The regular file after the symlink should still be fixed"
    assert_equals "Fixed: $TEST_TEMP_DIR/repo/plain.sh" "$out" "Only the regular file is reported"
    assert_equals "command grep x" "$(command cat "$TEST_TEMP_DIR/repo/plain.sh")" "plain.sh is fixed"
    assert_true "[ -L '$TEST_TEMP_DIR/repo/link.sh' ]" "Operand should still be a symlink"
    assert_equals "grep x" "$(command cat "$TEST_TEMP_DIR/outside/target.sh")" \
        "Symlink target should be untouched"
}

# Test: the fix replaces the file by rename, not by truncate-and-rewrite —
# a new inode, and a hard link to the old one still holds the old bytes
test_fixed_file_replaced_atomically() {
    write_fixture "$TEST_TEMP_DIR/test.sh" 'grep x' # enforce-command-prefix: off
    /usr/bin/ln "$TEST_TEMP_DIR/test.sh" "$TEST_TEMP_DIR/old.sh"
    local exit_code=0
    "$SCRIPT" "$TEST_TEMP_DIR/test.sh" >/dev/null || exit_code=$?
    assert_equals "1" "$exit_code" "Should exit 1 when changes made"
    assert_equals "command grep x" "$(command cat "$TEST_TEMP_DIR/test.sh")" \
        "Fixed content should be in place"
    assert_equals "grep x" "$(command cat "$TEST_TEMP_DIR/old.sh")" \
        "The old inode should be untouched (rename, not in-place write)"
}

# Test: how the hook reads the mode through stat. No usable answer, or a
# non-octal one → exit 2, original untouched, no tmpfile (never a silent 0600
# script). GNU's zero-stripped "44" (mode 044) and BSD 'stat -f %Lp' are applied.
test_mode_read_via_stat() {
    local exit_code err stub
    for stub in 'exit 1' 'printf "abc\n"'; do
        run_with_stub "$stub" stat
        assert_equals "2" "$exit_code" "stat '$stub' should exit 2"
        assert_contains "$err" "could not read the mode of $TEST_TEMP_DIR/test.sh" "Stderr names the file"
        assert_equals "grep x" "$(command cat "$TEST_TEMP_DIR/test.sh")" "Original should be unchanged"
        assert_equals "" "$(/usr/bin/find "$TEST_TEMP_DIR" -name '*.enforce.*')" "No tmpfile should be left"
    done
    run_with_stub 'printf "44\n"' stat
    assert_equals "44" "$(file_mode "$TEST_TEMP_DIR/test.sh")" "Zero-stripped mode 044 should be applied"
    run_with_stub 'case "$1" in -f) printf "750\n" ;; *) exit 1 ;; esac' stat
    assert_equals "1" "$exit_code" "BSD stat -f should supply the mode"
    assert_equals "750" "$(file_mode "$TEST_TEMP_DIR/test.sh")" "Mode should come from stat -f"
}

# Test: SIGTERM/SIGINT mid-rewrite (sent by a chmod stub while the tmpfile
# exists) exits 143/130, leaves the original intact and removes the tmpfile
test_signal_removes_tmpfile() {
    local exit_code err sig
    for sig in TERM:143 INT:130; do
        run_with_stub "kill -${sig%:*} \"\$PPID\"; exit 1" chmod
        assert_equals "${sig#*:}" "$exit_code" "SIG${sig%:*} should exit ${sig#*:}"
        assert_equals "grep x" "$(command cat "$TEST_TEMP_DIR/test.sh")" "Original should be intact"
        assert_equals "" "$(/usr/bin/find "$TEST_TEMP_DIR" -name '*.enforce.*')" \
            "The SIG${sig%:*} trap should remove the in-flight tmpfile"
    done
}

# Test: a failing chmod or mv → exit 2, the original intact, the tmpfile
# kept and named
test_replace_failure_keeps_tmpfile() {
    local exit_code err tool
    for tool in chmod mv; do
        run_with_stub 'exit 1' "$tool"
        assert_equals "2" "$exit_code" "A failed $tool should exit 2"
        assert_contains "$err" "fixed content kept at $TEST_TEMP_DIR/test.sh.enforce." "Stderr names the tmpfile"
        assert_equals "grep x" "$(command cat "$TEST_TEMP_DIR/test.sh")" "Original should be intact"
        /usr/bin/rm -rf "$TEST_TEMP_DIR/stub" "$TEST_TEMP_DIR"/test.sh.enforce.*
    done
}

# Test: a file in an unwritable directory stops the run — earlier fixes
# stand, later files are untouched, exit 2
test_unwritable_dir_stops_batch() {
    if [ "$(id -u)" -eq 0 ]; then
        skip_test "root can create files in a mode-555 directory"
        return
    fi
    /usr/bin/mkdir -p "$TEST_TEMP_DIR/ro"
    write_fixture "$TEST_TEMP_DIR/a.sh" 'grep x'    # enforce-command-prefix: off
    write_fixture "$TEST_TEMP_DIR/ro/b.sh" 'grep x' # enforce-command-prefix: off
    write_fixture "$TEST_TEMP_DIR/c.sh" 'grep x'    # enforce-command-prefix: off
    chmod 555 "$TEST_TEMP_DIR/ro"
    local exit_code=0 out
    out=$("$SCRIPT" "$TEST_TEMP_DIR/a.sh" "$TEST_TEMP_DIR/ro/b.sh" "$TEST_TEMP_DIR/c.sh" \
        2>/dev/null) || exit_code=$?
    chmod 755 "$TEST_TEMP_DIR/ro"
    assert_equals "2" "$exit_code" "Write failure should exit 2"
    assert_contains "$out" "Fixed: $TEST_TEMP_DIR/a.sh" "Earlier fix should be reported"
    assert_equals "command grep x" "$(command cat "$TEST_TEMP_DIR/a.sh")" \
        "Earlier file should stay fixed"
    assert_equals "grep x" "$(command cat "$TEST_TEMP_DIR/c.sh")" \
        "Later file should be untouched"
}

# Test: an unreadable file makes awk fail → exit 2, message, no tmpfile left
test_awk_failure_exits_2() {
    if [ "$(id -u)" -eq 0 ]; then
        skip_test "root can read a mode-000 file"
        return
    fi
    write_fixture "$TEST_TEMP_DIR/test.sh" 'grep x' # enforce-command-prefix: off
    chmod 000 "$TEST_TEMP_DIR/test.sh"
    local exit_code=0 err
    err=$("$SCRIPT" "$TEST_TEMP_DIR/test.sh" 2>&1 >/dev/null) || exit_code=$?
    chmod 644 "$TEST_TEMP_DIR/test.sh"
    assert_equals "2" "$exit_code" "awk failure should exit 2, not 0 or 1"
    assert_contains "$err" "awk failed" "Failure should be reported on stderr"
    local leftovers
    leftovers=$(/usr/bin/find "$TEST_TEMP_DIR" -name '*.enforce.*' | /usr/bin/wc -l)
    assert_equals "0" "$leftovers" "No tmpfile should be left behind"
}

# Run all tests
run_test test_file_mode_fallbacks "file_mode falls back to BSD stat, else prints nothing"
run_test test_fixed_file_keeps_mode "Fixed file keeps its mode"
run_test test_fixed_file_keeps_mode_without_gnu_chmod "Fixed file keeps its mode without GNU chmod"
run_test test_readonly_file_fixed_keeps_mode "Read-only file is fixed and keeps its mode"
run_test test_unwritable_dir_exits_2 "File in an unwritable directory exits 2"
run_test test_unwritable_dir_clean_exits_0 "Clean file in an unwritable directory exits 0"
run_test test_symlink_operand_skipped "Symlinked operand is skipped, target untouched"
run_test test_fixed_file_replaced_atomically "Fix replaces the file by rename, not in place"
run_test test_mode_read_via_stat "Mode via stat: unreadable/non-octal exit 2; zero-stripped and BSD -f applied"
run_test test_signal_removes_tmpfile "SIGTERM/SIGINT mid-rewrite exit 143/130 and remove the tmpfile"
run_test test_replace_failure_keeps_tmpfile "Failed chmod or mv exits 2 and keeps the named tmpfile"
run_test test_unwritable_dir_stops_batch "Unwritable directory stops the batch with exit 2"
run_test test_awk_failure_exits_2 "awk failure exits 2 and cleans up"

# Generate test report
generate_report
