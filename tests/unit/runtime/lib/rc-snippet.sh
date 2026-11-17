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

generate_report
