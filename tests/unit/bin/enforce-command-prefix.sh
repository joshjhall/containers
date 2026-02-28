#!/usr/bin/env bash
# Unit tests for bin/enforce-command-prefix.sh
# Tests the pre-commit hook that enforces 'command' prefix on common shell commands

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Bin Enforce Command Prefix Tests"

SCRIPT="$PROJECT_ROOT/bin/enforce-command-prefix.sh"

# Helper: write test fixture data to a file without triggering the hook.
# Uses a heredoc so the hook's heredoc exclusion protects the content.
write_fixture() {
    local file="$1"
    shift
    # Write each argument as a line
    for line in "$@"; do
        printf '%s\n' "$line"
    done > "$file"
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

# Test: Script exists and is executable
test_script_exists() {
    assert_file_exists "$SCRIPT"
    assert_executable "$SCRIPT"
}

# Test: Valid bash syntax
test_valid_syntax() {
    local exit_code=0
    bash -n "$SCRIPT" 2>/dev/null || exit_code=$?
    assert_equals "0" "$exit_code" "Script should have valid bash syntax"
}

# Test: No arguments → exit 0
test_no_args_exits_0() {
    local exit_code=0
    "$SCRIPT" || exit_code=$?
    assert_equals "0" "$exit_code" "Script should exit 0 when no files provided"
}

# Test: Bare command at start of line → fixed
test_bare_cmd_start_of_line() {
    write_fixture "$TEST_TEMP_DIR/test.sh" 'grep -q "pattern" file' # enforce-command-prefix: off
    local exit_code=0
    "$SCRIPT" "$TEST_TEMP_DIR/test.sh" || exit_code=$?
    assert_equals "1" "$exit_code" "Should exit 1 when changes made"
    local result
    result=$(/usr/bin/cat "$TEST_TEMP_DIR/test.sh")
    assert_equals 'command grep -q "pattern" file' "$result" "Should prepend command"
}

# Test: Bare command at start with leading whitespace
test_bare_cmd_with_indent() {
    write_fixture "$TEST_TEMP_DIR/test.sh" '    ls -la /tmp' # enforce-command-prefix: off
    local exit_code=0
    "$SCRIPT" "$TEST_TEMP_DIR/test.sh" || exit_code=$?
    assert_equals "1" "$exit_code" "Should exit 1 when changes made"
    local result
    result=$(/usr/bin/cat "$TEST_TEMP_DIR/test.sh")
    assert_equals '    command ls -la /tmp' "$result" "Should preserve indentation"
}

# Test: Bare command after pipe → fixed
test_bare_cmd_after_pipe() {
    write_fixture "$TEST_TEMP_DIR/test.sh" 'echo "hello" | grep "pattern"' # enforce-command-prefix: off
    local exit_code=0
    "$SCRIPT" "$TEST_TEMP_DIR/test.sh" || exit_code=$?
    assert_equals "1" "$exit_code" "Should exit 1 when changes made"
    local result
    result=$(/usr/bin/cat "$TEST_TEMP_DIR/test.sh")
    assert_equals 'echo "hello" | command grep "pattern"' "$result" "Should fix command after pipe"
}

# Test: Bare command after && → fixed
test_bare_cmd_after_and() {
    write_fixture "$TEST_TEMP_DIR/test.sh" 'true && grep -q "x" file' # enforce-command-prefix: off
    local exit_code=0
    "$SCRIPT" "$TEST_TEMP_DIR/test.sh" || exit_code=$?
    assert_equals "1" "$exit_code" "Should exit 1 when changes made"
    local result
    result=$(/usr/bin/cat "$TEST_TEMP_DIR/test.sh")
    assert_equals 'true && command grep -q "x" file' "$result" "Should fix command after &&"
}

# Test: Bare command after || → fixed
test_bare_cmd_after_or() {
    write_fixture "$TEST_TEMP_DIR/test.sh" 'false || cat /dev/null' # enforce-command-prefix: off
    local exit_code=0
    "$SCRIPT" "$TEST_TEMP_DIR/test.sh" || exit_code=$?
    assert_equals "1" "$exit_code" "Should exit 1 when changes made"
    local result
    result=$(/usr/bin/cat "$TEST_TEMP_DIR/test.sh")
    assert_equals 'false || command cat /dev/null' "$result" "Should fix command after ||"
}

# Test: Bare command after ; → fixed
test_bare_cmd_after_semicolon() {
    write_fixture "$TEST_TEMP_DIR/test.sh" 'echo "x"; sed -i "s/a/b/" file' # enforce-command-prefix: off
    local exit_code=0
    "$SCRIPT" "$TEST_TEMP_DIR/test.sh" || exit_code=$?
    assert_equals "1" "$exit_code" "Should exit 1 when changes made"
    local result
    result=$(/usr/bin/cat "$TEST_TEMP_DIR/test.sh")
    assert_equals 'echo "x"; command sed -i "s/a/b/" file' "$result" "Should fix command after ;"
}

# Test: Bare command after $( → fixed
test_bare_cmd_after_subshell() {
    write_fixture "$TEST_TEMP_DIR/test.sh" 'result=$(grep -c "x" file)' # enforce-command-prefix: off
    local exit_code=0
    "$SCRIPT" "$TEST_TEMP_DIR/test.sh" || exit_code=$?
    assert_equals "1" "$exit_code" "Should exit 1 when changes made"
    local result
    result=$(/usr/bin/cat "$TEST_TEMP_DIR/test.sh")
    assert_equals 'result=$(command grep -c "x" file)' "$result" "Should fix command after \$("
}

# Test: command command ls → command ls (deduplication)
test_dedup_command_command() {
    write_fixture "$TEST_TEMP_DIR/test.sh" 'command command ls -la' # enforce-command-prefix: off
    local exit_code=0
    "$SCRIPT" "$TEST_TEMP_DIR/test.sh" || exit_code=$?
    assert_equals "1" "$exit_code" "Should exit 1 when changes made"
    local result
    result=$(/usr/bin/cat "$TEST_TEMP_DIR/test.sh")
    assert_equals 'command ls -la' "$result" "Should deduplicate command command"
}

# Test: command command command grep → command grep (triple dedup)
test_dedup_triple_command() {
    write_fixture "$TEST_TEMP_DIR/test.sh" 'command command command grep -q "x" f' # enforce-command-prefix: off
    local exit_code=0
    "$SCRIPT" "$TEST_TEMP_DIR/test.sh" || exit_code=$?
    assert_equals "1" "$exit_code" "Should exit 1 when changes made"
    local result
    result=$(/usr/bin/cat "$TEST_TEMP_DIR/test.sh")
    assert_equals 'command grep -q "x" f' "$result" "Should deduplicate triple command"
}

# Test: Already-prefixed 'command grep' → unchanged
test_already_prefixed_unchanged() {
    write_fixture "$TEST_TEMP_DIR/test.sh" 'command grep -q "pattern" file'
    local exit_code=0
    "$SCRIPT" "$TEST_TEMP_DIR/test.sh" || exit_code=$?
    assert_equals "0" "$exit_code" "Should exit 0 when no changes needed"
    local result
    result=$(/usr/bin/cat "$TEST_TEMP_DIR/test.sh")
    assert_equals 'command grep -q "pattern" file' "$result" "Should not modify already-prefixed"
}

# Test: Comment line with bare command → unchanged
test_comment_line_unchanged() {
    write_fixture "$TEST_TEMP_DIR/test.sh" '# grep -q "pattern" file'
    local exit_code=0
    "$SCRIPT" "$TEST_TEMP_DIR/test.sh" || exit_code=$?
    assert_equals "0" "$exit_code" "Should exit 0 for comment lines"
    local result
    result=$(/usr/bin/cat "$TEST_TEMP_DIR/test.sh")
    assert_equals '# grep -q "pattern" file' "$result" "Should not modify comments"
}

# Test: Indented comment line → unchanged
test_indented_comment_unchanged() {
    write_fixture "$TEST_TEMP_DIR/test.sh" '    # cat /etc/os-release'
    local exit_code=0
    "$SCRIPT" "$TEST_TEMP_DIR/test.sh" || exit_code=$?
    assert_equals "0" "$exit_code" "Should exit 0 for indented comment lines"
}

# Test: Heredoc content with bare command → unchanged
test_heredoc_content_unchanged() {
    # Write fixture with heredoc — the 'cat' on line 1 gets fixed but body should not
    write_fixture "$TEST_TEMP_DIR/test.sh" \
        'cat <<EOF' \
        'grep -q "pattern" file' \
        'find /tmp -name "*.sh"' \
        'EOF' # enforce-command-prefix: off
    local exit_code=0
    "$SCRIPT" "$TEST_TEMP_DIR/test.sh" || exit_code=$?
    local result
    result=$(/usr/bin/cat "$TEST_TEMP_DIR/test.sh")
    assert_contains "$result" "grep -q \"pattern\" file" "Heredoc body should not be modified"
    assert_contains "$result" "find /tmp" "Heredoc body find should not be modified"
}

# Test: Heredoc with quoted delimiter → unchanged body
test_heredoc_quoted_delim() {
    write_fixture "$TEST_TEMP_DIR/test.sh" \
        "command cat <<'MARKER'" \
        'sed -i "s/a/b/" file' \
        'MARKER'
    local exit_code=0
    "$SCRIPT" "$TEST_TEMP_DIR/test.sh" || exit_code=$?
    assert_equals "0" "$exit_code" "Should exit 0 for already-prefixed with heredoc"
    local result
    result=$(/usr/bin/cat "$TEST_TEMP_DIR/test.sh")
    assert_contains "$result" 'sed -i "s/a/b/" file' "Quoted heredoc body should not be modified"
}

# Test: alias line → unchanged
test_alias_line_unchanged() {
    write_fixture "$TEST_TEMP_DIR/test.sh" "alias grep='rg --color=auto'"
    local exit_code=0
    "$SCRIPT" "$TEST_TEMP_DIR/test.sh" || exit_code=$?
    assert_equals "0" "$exit_code" "Should exit 0 for alias lines"
    local result
    result=$(/usr/bin/cat "$TEST_TEMP_DIR/test.sh")
    assert_equals "alias grep='rg --color=auto'" "$result" "Should not modify alias lines"
}

# Test: command -v grep → unchanged (not a bare command invocation)
test_command_v_unchanged() {
    write_fixture "$TEST_TEMP_DIR/test.sh" 'command -v grep >/dev/null'
    local exit_code=0
    "$SCRIPT" "$TEST_TEMP_DIR/test.sh" || exit_code=$?
    assert_equals "0" "$exit_code" "Should exit 0 for command -v"
    local result
    result=$(/usr/bin/cat "$TEST_TEMP_DIR/test.sh")
    assert_equals 'command -v grep >/dev/null' "$result" "Should not modify command -v"
}

# Test: Inline suppression marker → unchanged
test_suppression_marker() {
    write_fixture "$TEST_TEMP_DIR/test.sh" 'grep -q "pattern" file  # enforce-command-prefix: off'
    local exit_code=0
    "$SCRIPT" "$TEST_TEMP_DIR/test.sh" || exit_code=$?
    assert_equals "0" "$exit_code" "Should exit 0 for suppressed lines"
    local result
    result=$(/usr/bin/cat "$TEST_TEMP_DIR/test.sh")
    assert_contains "$result" 'grep -q "pattern" file' "Should not modify suppressed lines"
}

# Test: Command name as argument → unchanged
test_cmd_as_argument_unchanged() {
    write_fixture "$TEST_TEMP_DIR/test.sh" 'apt_install grep sed awk'
    local exit_code=0
    "$SCRIPT" "$TEST_TEMP_DIR/test.sh" || exit_code=$?
    assert_equals "0" "$exit_code" "Should exit 0 when cmd is an argument"
    local result
    result=$(/usr/bin/cat "$TEST_TEMP_DIR/test.sh")
    assert_equals 'apt_install grep sed awk' "$result" "Should not modify command used as argument"
}

# Test: Multiple bare commands in pipe chain → all fixed
test_multiple_cmds_pipe_chain() {
    write_fixture "$TEST_TEMP_DIR/test.sh" 'cat file | grep "x" | sort | head -5' # enforce-command-prefix: off
    local exit_code=0
    "$SCRIPT" "$TEST_TEMP_DIR/test.sh" || exit_code=$?
    assert_equals "1" "$exit_code" "Should exit 1 when changes made"
    local result
    result=$(/usr/bin/cat "$TEST_TEMP_DIR/test.sh")
    assert_contains "$result" "command cat" "Should fix cat"
    assert_contains "$result" "command grep" "Should fix grep"
    assert_contains "$result" "command sort" "Should fix sort"
    assert_contains "$result" "command head" "Should fix head"
}

# Test: Standalone command name on a line (e.g., just 'ls')
test_standalone_cmd() {
    write_fixture "$TEST_TEMP_DIR/test.sh" 'ls' # enforce-command-prefix: off
    local exit_code=0
    "$SCRIPT" "$TEST_TEMP_DIR/test.sh" || exit_code=$?
    assert_equals "1" "$exit_code" "Should exit 1 when changes made"
    local result
    result=$(/usr/bin/cat "$TEST_TEMP_DIR/test.sh")
    assert_equals 'command ls' "$result" "Should fix standalone command"
}

# Test: Non-target command → unchanged (e.g., echo, mkdir)
test_non_target_cmd_unchanged() {
    write_fixture "$TEST_TEMP_DIR/test.sh" 'echo "hello world"' 'mkdir -p /tmp/test'
    local exit_code=0
    "$SCRIPT" "$TEST_TEMP_DIR/test.sh" || exit_code=$?
    assert_equals "0" "$exit_code" "Should exit 0 for non-target commands"
}

# Test: File reports Fixed message
test_fixed_message() {
    write_fixture "$TEST_TEMP_DIR/test.sh" 'grep -q "x" file' # enforce-command-prefix: off
    local output
    output=$("$SCRIPT" "$TEST_TEMP_DIR/test.sh" 2>&1) || true
    assert_contains "$output" "Fixed:" "Should report fixed file"
    assert_contains "$output" "test.sh" "Should mention filename"
}

# Test: Clean file reports nothing
test_clean_no_output() {
    write_fixture "$TEST_TEMP_DIR/test.sh" 'command grep -q "x" file'
    local output
    output=$("$SCRIPT" "$TEST_TEMP_DIR/test.sh" 2>&1) || true
    assert_not_contains "$output" "Fixed" "Should not report Fixed for clean file"
}

# Test: Multiple files, some need fixing
test_multiple_files() {
    write_fixture "$TEST_TEMP_DIR/clean.sh" 'command grep -q "x" f'
    write_fixture "$TEST_TEMP_DIR/dirty.sh" 'grep -q "x" f' # enforce-command-prefix: off
    local exit_code=0
    "$SCRIPT" "$TEST_TEMP_DIR/clean.sh" "$TEST_TEMP_DIR/dirty.sh" || exit_code=$?
    assert_equals "1" "$exit_code" "Should exit 1 when any file was fixed"
}

# Test: All target commands are handled
test_all_target_commands() {
    # enforce-command-prefix: off
    write_fixture "$TEST_TEMP_DIR/test.sh" \
        'ls -la' \
        'cat file' \
        'grep "x" f' \
        'sed "s/a/b/" f' \
        'awk "{print}" f' \
        'head -5 f' \
        'tail -5 f' \
        'find /tmp -name "x"' \
        'sort f' \
        'wc -l f' \
        'tr "a" "b"' \
        'cut -d: -f1 f' \
        'tee output.log'
    local exit_code=0
    "$SCRIPT" "$TEST_TEMP_DIR/test.sh" || exit_code=$?
    assert_equals "1" "$exit_code" "Should exit 1 when changes made"
    local result
    result=$(/usr/bin/cat "$TEST_TEMP_DIR/test.sh")
    assert_contains "$result" "command ls" "ls should be prefixed"
    assert_contains "$result" "command cat" "cat should be prefixed"
    assert_contains "$result" "command grep" "grep should be prefixed"
    assert_contains "$result" "command sed" "sed should be prefixed"
    assert_contains "$result" "command awk" "awk should be prefixed"
    assert_contains "$result" "command head" "head should be prefixed"
    assert_contains "$result" "command tail" "tail should be prefixed"
    assert_contains "$result" "command find" "find should be prefixed"
    assert_contains "$result" "command sort" "sort should be prefixed"
    assert_contains "$result" "command wc" "wc should be prefixed"
    assert_contains "$result" "command tr" "tr should be prefixed"
    assert_contains "$result" "command cut" "cut should be prefixed"
    assert_contains "$result" "command tee" "tee should be prefixed"
}

# Test: Pipe at end of line (command after pipe with no args at EOL)
test_pipe_cmd_at_eol() {
    write_fixture "$TEST_TEMP_DIR/test.sh" 'echo "x" | sort' # enforce-command-prefix: off
    local exit_code=0
    "$SCRIPT" "$TEST_TEMP_DIR/test.sh" || exit_code=$?
    assert_equals "1" "$exit_code" "Should exit 1 when changes made"
    local result
    result=$(/usr/bin/cat "$TEST_TEMP_DIR/test.sh")
    assert_equals 'echo "x" | command sort' "$result" "Should fix pipe cmd at EOL"
}

# Test: Subshell command at end of line
test_subshell_cmd_at_eol() {
    write_fixture "$TEST_TEMP_DIR/test.sh" 'x=$(wc -l < file)' # enforce-command-prefix: off
    local exit_code=0
    "$SCRIPT" "$TEST_TEMP_DIR/test.sh" || exit_code=$?
    assert_equals "1" "$exit_code" "Should exit 1 when changes made"
    local result
    result=$(/usr/bin/cat "$TEST_TEMP_DIR/test.sh")
    assert_contains "$result" "command wc" "Should fix subshell cmd"
}

# Run all tests
run_test test_script_exists "Script exists and is executable"
run_test test_valid_syntax "Valid bash syntax"
run_test test_no_args_exits_0 "No arguments exits with code 0"
run_test test_bare_cmd_start_of_line "Bare command at start of line is fixed"
run_test test_bare_cmd_with_indent "Bare command with indent preserves whitespace"
run_test test_bare_cmd_after_pipe "Bare command after pipe is fixed"
run_test test_bare_cmd_after_and "Bare command after && is fixed"
run_test test_bare_cmd_after_or "Bare command after || is fixed"
run_test test_bare_cmd_after_semicolon "Bare command after semicolon is fixed"
run_test test_bare_cmd_after_subshell "Bare command after \$( is fixed"
run_test test_dedup_command_command "command command X is deduplicated"
run_test test_dedup_triple_command "Triple command is deduplicated"
run_test test_already_prefixed_unchanged "Already-prefixed command is unchanged"
run_test test_comment_line_unchanged "Comment line is unchanged"
run_test test_indented_comment_unchanged "Indented comment line is unchanged"
run_test test_heredoc_content_unchanged "Heredoc content is unchanged"
run_test test_heredoc_quoted_delim "Quoted heredoc delimiter is handled"
run_test test_alias_line_unchanged "Alias line is unchanged"
run_test test_command_v_unchanged "command -v is unchanged"
run_test test_suppression_marker "Inline suppression marker works"
run_test test_cmd_as_argument_unchanged "Command name as argument is unchanged"
run_test test_multiple_cmds_pipe_chain "Multiple commands in pipe chain all fixed"
run_test test_standalone_cmd "Standalone command name is fixed"
run_test test_non_target_cmd_unchanged "Non-target commands are unchanged"
run_test test_fixed_message "Fixed message is reported"
run_test test_clean_no_output "Clean file produces no output"
run_test test_multiple_files "Multiple files with mixed state"
run_test test_all_target_commands "All 13 target commands are handled"
run_test test_pipe_cmd_at_eol "Pipe command at end of line"
run_test test_subshell_cmd_at_eol "Subshell command at end of line"

# Generate test report
generate_report
