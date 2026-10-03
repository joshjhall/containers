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
    for k in ".." "." "a/b" "-x" "" ".venv"; do
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
    run_cmd -C "$S/myproj" prune myproj--issue-7
    assert_equals "0" "$RC" "exit status"
    assert_dir_not_exists "$S/cache/venvs/myproj--issue-7"
    assert_dir_not_exists "$S/cache/target/myproj--issue-7"
    assert_dir_exists "$S/cache/venvs/myproj"
    assert_dir_exists "$S/cache/venvs/myproj--issue-8"
    assert_dir_exists "$S/cache/venvs/other/myproj--issue-7"
}

# A symlinked entry is skipped outright. `rm -rf` on a bare symlink path would
# only unlink the link (never the target), so "target survives" alone passes
# without the guard; the LINK surviving and the nothing-found report are what
# fail if the [ -L ] guard is removed.
test_prune_skips_symlink() {
    command mkdir -p "$S/elsewhere" "$S/cache/venvs"
    command touch "$S/elsewhere/keep"
    command ln -s "$S/elsewhere" "$S/cache/venvs/myproj--issue-7"
    run_cmd -C "$S/myproj" prune myproj--issue-7
    assert_equals "0" "$RC" "exit status"
    assert_true "[ -L \"$S/cache/venvs/myproj--issue-7\" ]" "symlink left in place"
    assert_file_exists "$S/elsewhere/keep"
    assert_equals "artifact-dir prune: nothing under $S/cache/*/myproj--issue-7" "$OUT" "reports nothing pruned"
}

test_prune_nothing_found() {
    run_cmd -C "$S/myproj" prune myproj--issue-7
    assert_equals "0" "$RC" "exit status"
    assert_equals "artifact-dir prune: nothing under $S/cache/*/myproj--issue-7" "$OUT" "nothing-found report"
}

test_prune_real_run_output() {
    command mkdir -p "$S/cache/venvs/myproj--issue-7"
    run_cmd -C "$S/myproj" prune myproj--issue-7
    assert_equals "removing: $S/cache/venvs/myproj--issue-7" "$OUT" "real-run output"
    assert_dir_not_exists "$S/cache/venvs/myproj--issue-7"
}

# A mistyped preview flag must fail closed — usage error, nothing deleted.
test_prune_unknown_flag_fails_closed() {
    local f
    command mkdir -p "$S/cache/venvs/myproj--issue-7"
    for f in "--dryrun" "-n" "--dry_run"; do
        run_cmd -C "$S/myproj" prune myproj--issue-7 "$f"
        assert_equals "2" "$RC" "prune with '$f' is a usage error"
    done
    run_cmd -C "$S/myproj" prune myproj--issue-7 --dry-run extra
    assert_equals "2" "$RC" "extra arg after --dry-run is a usage error"
    assert_dir_exists "$S/cache/venvs/myproj--issue-7"
}

test_project_from_worktree() {
    run_cmd -C "$S/myproj/.worktrees/issue-7" --project
    assert_equals "0" "$RC" "exit status"
    assert_equals "myproj" "$OUT" "--project from a worktree is the main checkout name"
}

# A project name that itself contains "--" must survive intact.
test_project_name_with_double_dash() {
    command mkdir -p "$S/my--proj"
    command git -C "$S/my--proj" init -q -b main
    command git -C "$S/my--proj" commit -q --allow-empty -m init
    command git -C "$S/my--proj" worktree add -q -b feature/issue-9 "$S/my--proj/.worktrees/issue-9"
    run_cmd -C "$S/my--proj/.worktrees/issue-9" --project
    assert_equals "my--proj" "$OUT" "--project keeps an embedded --"
    run_cmd -C "$S/my--proj/.worktrees/issue-9" --name
    assert_equals "my--proj--issue-9" "$OUT" "--name keeps an embedded --"
}

# A main checkout named with "--" passes prune's shape check; run from inside
# that repo, prune must still refuse its own main-checkout name. A sibling
# worktree name of the same project stays prunable.
test_prune_refuses_double_dash_main_checkout() {
    local rc=0
    command mkdir -p "$S/my--proj" "$S/cache/venvs/my--proj" "$S/cache/venvs/my--proj--issue-9"
    command git -C "$S/my--proj" init -q -b main
    command git -C "$S/my--proj" commit -q --allow-empty -m init
    (builtin cd "$S/my--proj" && "$CMD" prune my--proj >/dev/null 2>&1) || rc=$?
    assert_equals "2" "$rc" "main-checkout name refused from inside the repo"
    assert_dir_exists "$S/cache/venvs/my--proj"
    rc=0
    (builtin cd "$S/my--proj" && "$CMD" prune my--proj--issue-9 >/dev/null 2>&1) || rc=$?
    assert_equals "0" "$rc" "worktree name still prunable"
    assert_dir_not_exists "$S/cache/venvs/my--proj--issue-9"
}

# One undeletable tree must not stop the other kinds being pruned. A read-only
# entry inside venvs/<name> makes that rm -rf fail for real (no stub), the way a
# #1004 phantom entry would; target/<name> must still be removed, the failure
# reported, and the exit non-zero.
test_prune_continues_past_a_failed_remove() {
    if [ "$(command id -u)" -eq 0 ]; then
        skip_test "root ignores directory write permission"
        return 0
    fi
    local rc=0 err
    command mkdir -p "$S/cache/venvs/myproj--issue-7/locked" "$S/cache/target/myproj--issue-7"
    command touch "$S/cache/venvs/myproj--issue-7/locked/f"
    command chmod 555 "$S/cache/venvs/myproj--issue-7/locked"
    err="$("$CMD" -C "$S/myproj" prune myproj--issue-7 2>&1 >/dev/null)" || rc=$?
    command chmod 755 "$S/cache/venvs/myproj--issue-7/locked"
    assert_equals "1" "$rc" "non-zero exit when a tree could not be removed"
    assert_dir_not_exists "$S/cache/target/myproj--issue-7"
    assert_contains "$err" "failed to remove: $S/cache/venvs/myproj--issue-7" "failure reported"
}

# A symlinked <kind> dir is skipped: rm -rf through it would delete outside
# the cache root.
test_prune_skips_symlinked_kind_dir() {
    command mkdir -p "$S/outside/myproj--issue-7"
    command touch "$S/outside/myproj--issue-7/keep"
    command ln -s "$S/outside" "$S/cache/evil"
    run_cmd -C "$S/myproj" prune myproj--issue-7
    assert_equals "0" "$RC" "exit status"
    assert_file_exists "$S/outside/myproj--issue-7/keep"
    assert_equals "artifact-dir prune: nothing under $S/cache/*/myproj--issue-7" "$OUT" "nothing pruned"
}

# Fail closed outside a checkout: with no project to scope to, refuse rather
# than fall back to a bare shape check (a "foo--bar" name could be another
# project's main checkout).
test_prune_refuses_outside_a_repo() {
    local rc=0
    command mkdir -p "$S/plain" "$S/cache/venvs/myproj--issue-7"
    GIT_CEILING_DIRECTORIES="$S" "$CMD" -C "$S/plain" prune myproj--issue-7 >/dev/null 2>&1 || rc=$?
    assert_equals "2" "$rc" "prune outside a checkout refused"
    assert_dir_exists "$S/cache/venvs/myproj--issue-7"
}

# Scoped to the resolved project: another project's dirs are refused, including
# the colliding case where project "myproj--issue" has its own main leaf that
# looks like a worktree name of "myproj".
test_prune_refuses_other_projects() {
    command mkdir -p "$S/cache/venvs/otherproj--issue-7" "$S/cache/venvs/myproj"
    run_cmd -C "$S/myproj" prune otherproj--issue-7
    assert_equals "2" "$RC" "another project's worktree dir refused"
    assert_dir_exists "$S/cache/venvs/otherproj--issue-7"
    run_cmd -C "$S/myproj" prune myproj--
    assert_equals "2" "$RC" "empty worktree part refused"
}

# Run from a linked worktree, the project still resolves to the main checkout,
# so a sibling worktree's dir is prunable and the main leaf is not.
test_prune_from_linked_worktree() {
    command mkdir -p "$S/cache/venvs/myproj--issue-8" "$S/cache/venvs/myproj"
    run_cmd -C "$S/myproj/.worktrees/issue-7" prune myproj--issue-8
    assert_equals "0" "$RC" "sibling worktree dir prunable"
    assert_dir_not_exists "$S/cache/venvs/myproj--issue-8"
    run_cmd -C "$S/myproj/.worktrees/issue-7" prune myproj
    assert_equals "2" "$RC" "main leaf refused from a worktree"
    assert_dir_exists "$S/cache/venvs/myproj"
}

# Bare repo: the common dir is <project>.git, so the .git suffix is stripped.
test_bare_repo_names() {
    command git init -q --bare -b main "$S/bareproj.git"
    command git -C "$S/myproj" push -q "$S/bareproj.git" main
    command git -C "$S/bareproj.git" worktree add -q "$S/wt-bare" main
    run_cmd -C "$S/wt-bare" --project
    assert_equals "bareproj" "$OUT" "--project strips .git"
    run_cmd -C "$S/wt-bare" --name
    assert_equals "bareproj--wt-bare" "$OUT" "--name in a bare repo's worktree"
}

test_arg_parsing_errors() {
    local args
    for args in "-C" "--name x" "--project x" "--no-create" "-x" "--help" "venvs extra"; do
        # shellcheck disable=SC2086 # word-splitting the case is intended
        run_cmd -C "$S/myproj" $args
        assert_equals "2" "$RC" "'$args' is a usage error"
    done
    assert_equals "" "$(command ls -A "$S/cache")" "nothing created under the cache root"
}

test_prune_dry_run_deletes_nothing() {
    command mkdir -p "$S/cache/venvs/myproj--issue-7"
    run_cmd -C "$S/myproj" prune myproj--issue-7 --dry-run
    assert_equals "0" "$RC" "exit status"
    assert_equals "would remove: $S/cache/venvs/myproj--issue-7" "$OUT" "dry-run output"
    assert_dir_exists "$S/cache/venvs/myproj--issue-7"
}

test_prune_refuses_main_checkout_name() {
    command mkdir -p "$S/cache/venvs/myproj"
    run_cmd -C "$S/myproj" prune myproj
    assert_equals "2" "$RC" "name without -- refused"
    assert_dir_exists "$S/cache/venvs/myproj"
}

test_prune_refuses_bad_names() {
    local n
    for n in "" "." ".." "a--b/c" "--x"; do
        run_cmd -C "$S/myproj" prune "$n"
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
run_test_with_setup test_prune_skips_symlink "prune skips a symlinked entry"
run_test_with_setup test_prune_nothing_found "prune with no matches reports and exits 0"
run_test_with_setup test_prune_real_run_output "prune reports each removed dir"
run_test_with_setup test_prune_unknown_flag_fails_closed "prune fails closed on an unknown flag"
run_test_with_setup test_project_from_worktree "--project from a worktree → <project>"
run_test_with_setup test_project_name_with_double_dash "project names containing -- are kept intact"
run_test_with_setup test_prune_refuses_double_dash_main_checkout "prune refuses a --named main checkout from inside it"
run_test_with_setup test_prune_continues_past_a_failed_remove "prune continues past a failed remove and reports it"
run_test_with_setup test_prune_skips_symlinked_kind_dir "prune skips a symlinked <kind> dir"
run_test_with_setup test_prune_refuses_outside_a_repo "prune refuses outside a checkout (fail closed)"
run_test_with_setup test_prune_refuses_other_projects "prune refuses other projects' dirs"
run_test_with_setup test_prune_from_linked_worktree "prune from a linked worktree scopes to the main project"
run_test_with_setup test_bare_repo_names "bare repo worktree naming"
run_test_with_setup test_arg_parsing_errors "malformed arguments are usage errors"
run_test_with_setup test_prune_dry_run_deletes_nothing "prune --dry-run deletes nothing"
run_test_with_setup test_prune_refuses_main_checkout_name "prune refuses a main-checkout name"
run_test_with_setup test_prune_refuses_bad_names "prune refuses empty/dot/slash/dash names"

generate_report
