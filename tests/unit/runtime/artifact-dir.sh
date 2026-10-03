#!/usr/bin/env bash
# Unit tests for lib/runtime/commands/artifact-dir (#1005).
#
# These tests EXECUTE the command against real git repos and linked worktrees
# built in scratch, and compare its output to LITERAL expected paths. A substring
# check ("contains --") would pass for a wrong project or worktree name; the
# literal comparison is what discriminates.
#
# NO TEST HERE USES `|| return 1`: run_test() never calls fail_test() on a
# non-zero return, so a bare `return 1` drops the test from the totals. Every
# failure path goes through an assert_* call.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"
init_test_framework

test_suite "artifact-dir per-checkout /cache build-artifact paths"

CMD="$PROJECT_ROOT/lib/runtime/commands/artifact-dir"

# Hermetic git: a leaked GIT_DIR (pre-push hook) would point every rev-parse at
# the outer repo, and committing needs an identity.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR 2>/dev/null || true
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

# Scratch under TEST_SCRATCH_BASE, not the repo: the repo's FUSE mount loses
# write-then-read coherency (#821). Layout:
#   $S/myproj                      main checkout
#   $S/myproj/.worktrees/issue-7   linked worktree
#   $S/cache                       ARTIFACT_CACHE_ROOT
setup() {
    S="$(command mktemp -d "$TEST_SCRATCH_BASE/artifact-dir.XXXXXX")"
    command mkdir -p "$S/myproj" "$S/cache"
    command git -C "$S/myproj" init -q -b main
    command git -C "$S/myproj" commit -q --allow-empty -m init
    command git -C "$S/myproj" worktree add -q -b feature/issue-7 "$S/myproj/.worktrees/issue-7"
    export ARTIFACT_CACHE_ROOT="$S/cache"
}

teardown() {
    command rm -rf "${S:-}" 2>/dev/null || true
    unset S ARTIFACT_CACHE_ROOT
}

run_test_with_setup() {
    setup
    run_test "$1" "$2"
    teardown
}

# Runs the command, capturing stdout into OUT and the exit status into RC.
run_cmd() {
    RC=0
    OUT="$("$CMD" "$@" 2>/dev/null)" || RC=$?
}

# ---------------------------------------------------------------------------

test_main_checkout_name() {
    run_cmd -C "$S/myproj" --name
    assert_equals "0" "$RC" "exit status"
    assert_equals "myproj" "$OUT" "main checkout name is the project dir"
}

test_linked_worktree_name() {
    run_cmd -C "$S/myproj/.worktrees/issue-7" --name
    assert_equals "0" "$RC" "exit status"
    assert_equals "myproj--issue-7" "$OUT" "worktree name is <project>--<worktree-dir>"
}

# From a subdirectory of the worktree the name must not change — the checkout,
# not the cwd, decides it.
test_worktree_subdir_same_name() {
    command mkdir -p "$S/myproj/.worktrees/issue-7/src/deep"
    run_cmd -C "$S/myproj/.worktrees/issue-7/src/deep" --name
    assert_equals "myproj--issue-7" "$OUT" "name from a subdir"
}

test_kind_creates_and_prints_path() {
    run_cmd -C "$S/myproj/.worktrees/issue-7" venvs
    assert_equals "0" "$RC" "exit status"
    assert_equals "$S/cache/venvs/myproj--issue-7" "$OUT" "printed path"
    assert_dir_exists "$S/cache/venvs/myproj--issue-7"
}

test_no_create_does_not_create() {
    run_cmd -C "$S/myproj" --no-create target
    assert_equals "$S/cache/target/myproj" "$OUT" "printed path"
    assert_dir_not_exists "$S/cache/target/myproj"
}

test_invalid_kind_rejected() {
    local k
    for k in ".." "." "a/b" "-x" ""; do
        run_cmd -C "$S/myproj" "$k"
        assert_equals "2" "$RC" "kind '$k' is a usage error"
    done
    assert_equals "" "$(command ls -A "$S/cache")" "nothing created under the cache root"
}

test_not_a_git_checkout() {
    command mkdir -p "$S/plain"
    # GIT_CEILING_DIRECTORIES stops discovery from walking up into an enclosing
    # repo (the scratch base may sit inside one).
    RC=0
    GIT_CEILING_DIRECTORIES="$S" "$CMD" -C "$S/plain" venvs >/dev/null 2>&1 || RC=$?
    assert_equals "1" "$RC" "outside a checkout"
}

test_no_args_is_usage_error() {
    run_cmd
    assert_equals "2" "$RC" "no args"
}

# prune removes exactly /cache/*/<name> and nothing else: not the main
# checkout's dir, not a different worktree's dir, not a nested match.
test_prune_removes_only_matching() {
    command mkdir -p "$S/cache/venvs/myproj--issue-7/lib" \
        "$S/cache/target/myproj--issue-7" \
        "$S/cache/venvs/myproj" \
        "$S/cache/venvs/myproj--issue-8" \
        "$S/cache/venvs/other/myproj--issue-7"
    run_cmd prune myproj--issue-7
    assert_equals "0" "$RC" "exit status"
    assert_dir_not_exists "$S/cache/venvs/myproj--issue-7"
    assert_dir_not_exists "$S/cache/target/myproj--issue-7"
    assert_dir_exists "$S/cache/venvs/myproj"
    assert_dir_exists "$S/cache/venvs/myproj--issue-8"
    assert_dir_exists "$S/cache/venvs/other/myproj--issue-7"
}

# A symlinked entry is not followed into: its target must survive.
test_prune_skips_symlink() {
    command mkdir -p "$S/elsewhere" "$S/cache/venvs"
    command touch "$S/elsewhere/keep"
    command ln -s "$S/elsewhere" "$S/cache/venvs/myproj--issue-7"
    run_cmd prune myproj--issue-7
    assert_file_exists "$S/elsewhere/keep"
}

test_prune_dry_run_deletes_nothing() {
    command mkdir -p "$S/cache/venvs/myproj--issue-7"
    run_cmd prune myproj--issue-7 --dry-run
    assert_equals "0" "$RC" "exit status"
    assert_equals "would remove: $S/cache/venvs/myproj--issue-7" "$OUT" "dry-run output"
    assert_dir_exists "$S/cache/venvs/myproj--issue-7"
}

test_prune_refuses_main_checkout_name() {
    command mkdir -p "$S/cache/venvs/myproj"
    run_cmd prune myproj
    assert_equals "2" "$RC" "name without -- refused"
    assert_dir_exists "$S/cache/venvs/myproj"
}

test_prune_refuses_bad_names() {
    local n
    for n in "" "." ".." "a--b/c" "--x"; do
        run_cmd prune "$n"
        assert_equals "2" "$RC" "prune '$n' refused"
    done
}

run_test_with_setup test_main_checkout_name "main checkout → <project>"
run_test_with_setup test_linked_worktree_name "linked worktree → <project>--<dir>"
run_test_with_setup test_worktree_subdir_same_name "subdir of worktree keeps the checkout name"
run_test_with_setup test_kind_creates_and_prints_path "<kind> creates and prints the path"
run_test_with_setup test_no_create_does_not_create "--no-create prints without creating"
run_test_with_setup test_invalid_kind_rejected "invalid kinds are usage errors"
run_test_with_setup test_not_a_git_checkout "outside a git checkout exits 1"
run_test_with_setup test_no_args_is_usage_error "no args is a usage error"
run_test_with_setup test_prune_removes_only_matching "prune removes only /cache/*/<name>"
run_test_with_setup test_prune_skips_symlink "prune does not follow a symlinked entry"
run_test_with_setup test_prune_dry_run_deletes_nothing "prune --dry-run deletes nothing"
run_test_with_setup test_prune_refuses_main_checkout_name "prune refuses a main-checkout name"
run_test_with_setup test_prune_refuses_bad_names "prune refuses empty/dot/slash/dash names"

generate_report
