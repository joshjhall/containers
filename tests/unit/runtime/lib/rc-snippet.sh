#!/usr/bin/env bash
# Unit tests for lib/runtime/lib/rc-snippet.sh (#1721)

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Runtime rc-snippet Helper Tests"

SOURCE_FILE="$PROJECT_ROOT/lib/runtime/lib/rc-snippet.sh"

# A block with shell metacharacters and quotes, like the real legacy snippets.
BLOCK='# tool: TOKEN
if command -v tool >/dev/null 2>&1; then
    export TOKEN=$(tool token | command tr -d '"'"'[:space:]'"'"')
fi'

setup() {
    TEST_TEMP_DIR=$(command mktemp -d "$TEST_SCRATCH_BASE/test-rc-snippet-XXXXXX")
    RC="$TEST_TEMP_DIR/.bashrc"
}

teardown() {
    command rm -rf "${TEST_TEMP_DIR:-}" 2>/dev/null || true
    unset TEST_TEMP_DIR RC
}

run_test_with_setup() {
    setup
    run_test "$1" "$2"
    teardown
}

# Run rc_remove_block in a subshell (fresh source each time) and print its rc.
_remove() {
    local rc=0
    (. "$SOURCE_FILE" && rc_remove_block "$1" "$2") || rc=$?
    printf '%s' "$rc"
}

test_sourced_only_with_guard() {
    assert_file_exists "$SOURCE_FILE" "rc-snippet.sh exists"
    assert_executable "$SOURCE_FILE" "rc-snippet.sh is executable (installed alongside op-usable.sh)"
    assert_file_contains "$SOURCE_FILE" "_RC_SNIPPET_LOADED" "Has a multiple-source guard"
    assert_file_not_contains "$SOURCE_FILE" "^[^#]*\\(python\\|perl\\)" "Pure bash + awk: no python/perl outside comments (minimal images)"
}

test_removes_exact_block_and_preceding_blank() {
    printf 'before\n\n%s\nafter\n' "$BLOCK" >"$RC"
    assert_equals "0" "$(_remove "$RC" "$BLOCK")" "Returns 0 when the block is removed"
    assert_equals "$(printf 'before\nafter')" "$(command cat "$RC")" \
        "Block and the one blank line before it are removed; surroundings kept"
}

test_block_on_first_line() {
    printf '%s\nafter\n' "$BLOCK" >"$RC"
    assert_equals "0" "$(_remove "$RC" "$BLOCK")" "Removes a block starting on line 1"
    assert_equals "after" "$(command cat "$RC")" "Only the trailing content remains"
}

test_only_one_blank_line_consumed() {
    printf 'before\n\n\n%s\n' "$BLOCK" >"$RC"
    _remove "$RC" "$BLOCK" >/dev/null
    assert_equals "before|" "$(command paste -sd"|" "$RC")" \
        "Exactly one of the two preceding blank lines is consumed"
}

test_hand_edited_block_left_alone() {
    local edited="${BLOCK/tool token/tool token --verbose}"
    printf 'before\n%s\nafter\n' "$edited" >"$RC"
    local orig
    orig=$(command cat "$RC")
    assert_equals "1" "$(_remove "$RC" "$BLOCK")" "Returns 1 when only a near-match exists"
    assert_equals "$orig" "$(command cat "$RC")" "A hand-edited block is left untouched"
}

test_missing_file_returns_1() {
    assert_equals "1" "$(_remove "$TEST_TEMP_DIR/nope" "$BLOCK")" "Missing file returns 1"
    assert_file_not_exists "$TEST_TEMP_DIR/nope" "Missing file is not created"
}

test_idempotent() {
    printf 'before\n%s\nafter\n' "$BLOCK" >"$RC"
    _remove "$RC" "$BLOCK" >/dev/null
    local once
    once=$(command cat "$RC")
    assert_equals "1" "$(_remove "$RC" "$BLOCK")" "Second call finds nothing to remove"
    assert_equals "$once" "$(command cat "$RC")" "Second call leaves the file unchanged"
}

test_no_temp_files_left() {
    printf 'before\n%s\n' "$BLOCK" >"$RC"
    _remove "$RC" "$BLOCK" >/dev/null
    assert_equals "1" "$(command find "$TEST_TEMP_DIR" -type f | command wc -l | command tr -d ' ')" \
        "Only the rc file remains (temp file cleaned up)"
}

run_test_with_setup test_sourced_only_with_guard "Helper exists, is guarded and python-free"
run_test_with_setup test_removes_exact_block_and_preceding_blank "Exact block + one preceding blank line removed"
run_test_with_setup test_block_on_first_line "Block on line 1 is removed"
run_test_with_setup test_only_one_blank_line_consumed "Only one preceding blank line consumed"
run_test_with_setup test_hand_edited_block_left_alone "Hand-edited block left untouched"
run_test_with_setup test_missing_file_returns_1 "Missing rc file returns 1"
run_test_with_setup test_idempotent "Removal is idempotent"
run_test_with_setup test_no_temp_files_left "Temp file is cleaned up"

test_trailing_newline_in_text_ignored() {
    printf 'before\n%s\nafter\n' "$BLOCK" >"$RC"
    assert_equals "0" "$(_remove "$RC" "$BLOCK"$'\n')" "TEXT with a trailing newline still matches"
    assert_equals "$(printf 'before\nafter')" "$(command cat "$RC")" "Block removed despite trailing newline in TEXT"
}

test_empty_text_never_matches() {
    printf 'before\n\nafter\n' >"$RC"
    local orig
    orig=$(command cat "$RC")
    assert_equals "1" "$(_remove "$RC" "")" "Empty TEXT returns 1 (not a false 'removed')"
    assert_equals "$orig" "$(command cat "$RC")" "Empty TEXT leaves the file unchanged"
}

test_mode_preserved() {
    printf 'before\n%s\n' "$BLOCK" >"$RC"
    command chmod 600 "$RC"
    _remove "$RC" "$BLOCK" >/dev/null
    assert_equals "600" "$(command stat -c %a "$RC")" "In-place rewrite keeps the rc file's mode"
}

# A copy-back that fails after the redirect truncated FILE must keep the temp
# file (the only complete copy), name it, and return 2 — never delete it.
test_failed_copy_back_keeps_full_copy() {
    printf 'before\n%s\nafter\n' "$BLOCK" >"$RC"
    command mkdir -p "$TEST_TEMP_DIR/stub"
    printf '#!/bin/sh\nexit 1\n' >"$TEST_TEMP_DIR/stub/cat"
    command chmod +x "$TEST_TEMP_DIR/stub/cat"
    local out rc=0
    # BASH_ENV is unset: it rebuilds PATH in non-interactive bash, dropping the stub.
    out=$(command env -u BASH_ENV PATH="$TEST_TEMP_DIR/stub:$PATH" bash -c '. "$1" && rc_remove_block "$2" "$3"; st=$?; printf "%s|%s" "$st" "$RC_REMOVE_BLOCK_KEPT"' _ "$SOURCE_FILE" "$RC" "$BLOCK") || rc=$?
    assert_equals "0" "$rc" "Probe shell itself succeeds"
    assert_equals "2" "${out%%|*}" "Failed copy-back returns 2"
    local kept="${out#*|}"
    assert_file_exists "$kept" "The temp file holding the edited content is kept"
    assert_equals "$(printf 'before\nafter')" "$(command cat "$kept")" \
        "The kept file holds the complete edited content"
}

run_test_with_setup test_trailing_newline_in_text_ignored "Trailing newline on TEXT is ignored"
run_test_with_setup test_empty_text_never_matches "Empty TEXT never matches"
run_test_with_setup test_mode_preserved "rc file mode preserved by in-place rewrite"
run_test_with_setup test_failed_copy_back_keeps_full_copy "Failed copy-back keeps the full copy and returns 2"

# The matcher must not read past EOF: an unset awk element is "", so a TEXT
# ending in a blank line could otherwise "match" a block that ends the file.
test_no_match_past_eof() {
    printf 'x\na\n' >"$RC"
    assert_equals "1" "$(_remove "$RC" $'a\n\n')" "A trailing blank in TEXT cannot match beyond EOF"
    assert_equals "x|a" "$(command paste -sd'|' "$RC")" "File unchanged when the match would run past EOF"
}

test_truncated_block_at_eof_left_alone() {
    printf 'before\n%s\n' "${BLOCK%$'\n'*}" >"$RC"
    local orig
    orig=$(command cat "$RC")
    assert_equals "1" "$(_remove "$RC" "$BLOCK")" "A block cut short by EOF is not a match"
    assert_equals "$orig" "$(command cat "$RC")" "Truncated block left untouched"
}

run_test_with_setup test_no_match_past_eof "Matcher never reads past EOF"
run_test_with_setup test_truncated_block_at_eof_left_alone "Block truncated at EOF left untouched"

generate_report
