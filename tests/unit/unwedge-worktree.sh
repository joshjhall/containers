#!/usr/bin/env bash
# Unit tests for lib/runtime/commands/unwedge-worktree.
#
# The command exists because a worktree tree under the macOS virtiofs mount can
# reach a state where its entries appear in `readdir` but every `stat`/`unlink`/
# `rename` on them returns EBADF, so `rm -rf` can never empty the directory and
# teardown leaves the `issue-N` path occupied. The command sidesteps that by
# renaming the tree aside rather than deleting it.
#
# These tests EXECUTE the command against real directories and assert on
# observable filesystem state — not on the presence of strings in the script.
# A grep-for-source-text test would pass against a command that never ran.
#
# NO TEST HERE USES `|| return 1`. run_test() only calls pass_test() when the
# test function returns 0 — it never calls fail_test() on a non-zero return — so
# a bare `return 1` makes a test count as NEITHER passed nor failed and it
# silently disappears from the totals. Verified against the framework: a test
# body of `return 1` reports "Total 1 / Passed 0 / Failed 0". Every failure path
# below therefore goes through an assert_* / fail_test call, which is what
# actually increments the failure counter.
#
# The EBADF condition itself cannot be manufactured on a normal filesystem (it
# takes a host virtiofsd that has dropped an inode mapping), so the wedged case
# is not simulated here. What IS tested is the property that makes the command
# work on a wedged tree: it never needs to open, stat, or unlink the CHILDREN,
# only rename the parent. A rewrite that reintroduced a recursive delete would
# still pass a "did the path get freed" check on clean fixtures, so
# test_does_not_delete_contents pins the contents as SURVIVING the move —
# that is the assertion a delete-based implementation fails.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"
init_test_framework

test_suite "unwedge-worktree frees a wedged worktree path by quarantine"

CMD="$PROJECT_ROOT/lib/runtime/commands/unwedge-worktree"

# Each test gets its own scratch dir. TEST_SCRATCH_BASE (not the reports dir)
# because scratch inside the repo is served over the same incoherent FUSE mount
# this command exists to work around (#821).
new_scratch() {
    local d
    d="$(command mktemp -d "$TEST_SCRATCH_BASE/unwedge.XXXXXX")"
    command echo "$d"
}

test_command_is_executable() {
    assert_file_exists "$CMD"
    assert_executable "$CMD"
}

# The core behaviour: the requested path is free afterwards, and free for REUSE
# — a caller's next `worktree-new` must be able to recreate it.
test_frees_the_path_for_reuse() {
    local s
    s="$(new_scratch)"
    command mkdir -p "$s/issue-1/target/debug"
    command touch "$s/issue-1/target/debug/a.o"

    assert_true "\"$CMD\" \"$s/issue-1\" >/dev/null" "command succeeds"

    assert_dir_not_exists "$s/issue-1"
    command mkdir -p "$s/issue-1" 2>/dev/null
    assert_dir_exists "$s/issue-1"
}

# THE discriminating test. On a genuinely wedged tree the contents CANNOT be
# deleted, so an implementation that tries is broken even though the path still
# ends up free on a clean fixture. Asserting the contents survive is what
# separates "renamed aside" from "deleted".
test_does_not_delete_contents() {
    local s quarantined
    s="$(new_scratch)"
    command mkdir -p "$s/issue-2/target/debug"
    command echo payload >"$s/issue-2/target/debug/a.o"

    assert_true "\"$CMD\" \"$s/issue-2\" >/dev/null" "command succeeds"

    quarantined="$(command find "$s" -maxdepth 1 -name '.wedged-issue-2-*' | command head -n1)"
    assert_not_empty "$quarantined" "tree was moved to a quarantine path"
    assert_file_exists "$quarantined/target/debug/a.o"
    assert_equals "payload" "$(command cat "$quarantined/target/debug/a.o")" \
        "quarantined content is intact"
}

# Teardown callers run this unconditionally, so an absent path is the state they
# wanted and must not be an error.
test_absent_path_is_success() {
    local s
    s="$(new_scratch)"
    "$CMD" "$s/nope" >/dev/null
    assert_equals "0" "$?" "absent path exits 0"
}

# Two quarantines of the same name must sit BESIDE each other. If the second
# collided it would be renamed INTO the first, nesting one wedged tree inside
# another and hiding it from --list.
test_repeated_quarantine_does_not_collide() {
    local s count
    s="$(new_scratch)"
    command mkdir -p "$s/issue-3"
    assert_true "\"$CMD\" \"$s/issue-3\" >/dev/null" "first quarantine succeeds"
    command mkdir -p "$s/issue-3"
    assert_true "\"$CMD\" \"$s/issue-3\" >/dev/null" "second quarantine succeeds"

    count="$(command find "$s" -maxdepth 1 -name '.wedged-issue-3-*' | command wc -l | command tr -d '[:space:]')"
    assert_equals "2" "$count" "both quarantined trees are siblings"
}

# A symlink must be refused: renaming it moves the link, not the wedged tree,
# and following it would quarantine an unrelated directory.
test_refuses_symlink() {
    local s
    s="$(new_scratch)"
    command mkdir -p "$s/real"
    command ln -s real "$s/link"

    if "$CMD" "$s/link" >/dev/null 2>&1; then
        fail_test "symlink was accepted instead of refused"
    fi
    # Count rather than glob-test: a `[ ! -e ... ]` on an unmatched glob is
    # trivially true and would assert nothing.
    assert_equals "0" \
        "$(command find "$s" -maxdepth 1 -name '.wedged-*' | command wc -l | command tr -d '[:space:]')" \
        "no quarantine was created for a symlink"
    assert_dir_exists "$s/real" "symlink target is untouched"
    assert_true "[ -L '$s/link' ]" "symlink itself is untouched"
}

test_refuses_regular_file() {
    local s
    s="$(new_scratch)"
    command touch "$s/afile"

    if "$CMD" "$s/afile" >/dev/null 2>&1; then
        fail_test "regular file was accepted instead of refused"
    fi
    assert_file_exists "$s/afile" "regular file is untouched"
}

# A trailing slash must resolve to the same parent — a naive string-slice of the
# path would compute the wrong parent and quarantine into the wrong directory.
test_handles_trailing_slash() {
    local s count
    s="$(new_scratch)"
    command mkdir -p "$s/issue-4"

    assert_true "\"$CMD\" \"$s/issue-4/\" >/dev/null" "trailing-slash path is moved"

    assert_dir_not_exists "$s/issue-4"
    count="$(command find "$s" -maxdepth 1 -name '.wedged-issue-4-*' | command wc -l | command tr -d '[:space:]')"
    assert_equals "1" "$count" "quarantined beside the original, not elsewhere"
}

test_list_reports_quarantined_trees() {
    local s out
    s="$(new_scratch)"
    command mkdir -p "$s/issue-5/sub"
    command touch "$s/issue-5/sub/f"
    assert_true "\"$CMD\" \"$s/issue-5\" >/dev/null" "command succeeds"

    out="$("$CMD" --list "$s")"
    assert_contains "$out" ".wedged-issue-5-" "list names the quarantined tree"
    # Assert the REAL count (sub/ plus sub/f = 2), not merely that the word
    # "entries" appears — and assert the "none" message is ABSENT. Without both,
    # a --list that printed the rows and then also claimed nothing was
    # quarantined would still pass.
    assert_contains "$out" "(2 entries)" "list reports the true entry count"
    assert_not_contains "$out" "no quarantined trees" "does not also report none"
}

test_list_on_clean_dir_reports_nothing() {
    local s out
    s="$(new_scratch)"
    out="$("$CMD" --list "$s")"
    assert_contains "$out" "no quarantined trees" "clean dir reports none"
}

# Usage errors must be distinguishable from a failed rename, so callers can tell
# "I called it wrong" from "the filesystem refused".
test_usage_errors_exit_2() {
    local s
    s="$(new_scratch)"
    "$CMD" >/dev/null 2>&1
    assert_equals "2" "$?" "no args exits 2"
    "$CMD" a b >/dev/null 2>&1
    assert_equals "2" "$?" "too many args exits 2"
    "$CMD" --list "$s" x >/dev/null 2>&1
    assert_equals "2" "$?" "bad --list arity exits 2"
    "$CMD" --list "$s/missing" >/dev/null 2>&1
    assert_equals "2" "$?" "--list on missing dir exits 2"
}

# The command frees a path; it does NOT reclaim disk. Wedged entries have no
# reachable inodes, so any output promising space would be false on the only
# platform where this runs.
test_output_does_not_claim_reclaimed_space() {
    local s out
    s="$(new_scratch)"
    command mkdir -p "$s/issue-6"
    out="$("$CMD" "$s/issue-6")"
    assert_contains "$out" "no reclaimable space" "states that no space is freed"
}

test_installed_by_dockerfile() {
    assert_file_contains "$PROJECT_ROOT/Dockerfile" \
        "COPY lib/runtime/commands/unwedge-worktree /usr/local/bin/unwedge-worktree" \
        "Dockerfile installs the command"
    # The chmod line lists the command among its continuation-line operands.
    # Matched without the trailing backslash: assert_file_contains treats the
    # pattern as a regex, where a lone trailing backslash is not a literal.
    assert_file_contains "$PROJECT_ROOT/Dockerfile" \
        "    /usr/local/bin/unwedge-worktree" \
        "Dockerfile makes it executable"
}

run_test test_command_is_executable "command exists and is executable"
run_test test_frees_the_path_for_reuse "frees the worktree path for reuse"
run_test test_does_not_delete_contents "moves contents aside rather than deleting them"
run_test test_absent_path_is_success "absent path is a successful no-op"
run_test test_repeated_quarantine_does_not_collide "repeated quarantine does not nest"
run_test test_refuses_symlink "refuses a symlink"
run_test test_refuses_regular_file "refuses a regular file"
run_test test_handles_trailing_slash "resolves a trailing slash to the right parent"
run_test test_list_reports_quarantined_trees "--list reports quarantined trees"
run_test test_list_on_clean_dir_reports_nothing "--list on a clean dir reports none"
run_test test_usage_errors_exit_2 "usage errors exit 2"
run_test test_output_does_not_claim_reclaimed_space "output does not claim reclaimed space"
run_test test_installed_by_dockerfile "Dockerfile installs the command"

generate_report
