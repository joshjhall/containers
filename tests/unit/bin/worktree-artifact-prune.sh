#!/usr/bin/env bash
# Unit tests for bin/worktree-artifact-prune.sh — the artifact-dir prune tail of
# `just worktree-rm` (#1015).
#
# The tail carries the "never delete unprompted" guarantee for the per-checkout
# build-artifact dirs (#1005): without a TTY it may only LIST the dirs and print
# the prune command. These tests run it against a real scratch git project and a
# scratch ARTIFACT_CACHE_ROOT and compare stdout to LITERAL expected text — a
# substring check would pass for a wrong project name or an extra line.
#
# NO TEST HERE USES `|| return 1`: run_test() never calls fail_test() on a
# non-zero return, so a bare `return 1` drops the test from the totals. Every
# failure path goes through an assert_* call.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"
init_test_framework

test_suite "worktree-artifact-prune.sh — worktree-rm artifact-dir prune tail"

SCRIPT="$PROJECT_ROOT/bin/worktree-artifact-prune.sh"

# Hermetic git: a leaked GIT_DIR (pre-push hook) would point every rev-parse at
# the outer repo, and committing needs an identity.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR 2>/dev/null || true
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

# Pin the in-repo artifact-dir so an installed copy on PATH never stands in.
export WORKTREE_PRUNE_ARTIFACT_DIR_BIN="$PROJECT_ROOT/lib/runtime/commands/artifact-dir"

# Scratch under TEST_SCRATCH_BASE, not the repo: the repo's FUSE mount loses
# write-then-read coherency (#821). Layout:
#   $S/myproj   main checkout (the worktree itself is already gone at this point
#               in worktree-rm, so none is created)
#   $S/cache    ARTIFACT_CACHE_ROOT
#   $S/nowhere  a directory outside any git project
setup() {
    S="$(command mktemp -d "$TEST_SCRATCH_BASE/worktree-artifact-prune.XXXXXX")"
    command mkdir -p "$S/myproj" "$S/cache" "$S/nowhere"
    command git -C "$S/myproj" init -q -b main
    command git -C "$S/myproj" commit -q --allow-empty -m init
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

# Seed the two orphaned dirs issue-7 leaves behind.
seed_issue7() {
    command mkdir -p "$S/cache/cargo/myproj--issue-7/debug" "$S/cache/node/myproj--issue-7"
}

# Runs the script with no TTY (stdin /dev/null, stdout captured) from cwd $1.
# Sets OUT (stdout) and RC.
run_notty() {
    local cwd="$1"
    shift
    RC=0
    OUT="$(cd "$cwd" && bash "$SCRIPT" "$@" </dev/null 2>/dev/null)" || RC=$?
}

# Runs the script on a pty via util-linux `script`, feeding $2 as the answer.
# Sets OUT (the pty transcript) and RC.
run_tty() {
    local cwd="$1" answer="$2"
    RC=0
    OUT="$(cd "$cwd" && command printf '%s\n' "$answer" |
        command script -q -e -c "bash '$SCRIPT' 7" /dev/null 2>/dev/null)" || RC=$?
}

# ---------------------------------------------------------------------------

# The core guarantee: no TTY means list + hint, and nothing is deleted. Fails if
# the tail is ever changed to prune without the TTY prompt.
test_notty_lists_and_deletes_nothing() {
    seed_issue7
    run_notty "$S/myproj" 7
    local expected
    expected="Build-artifact dirs left by issue-7:
  $S/cache/cargo/myproj--issue-7
  $S/cache/node/myproj--issue-7
  remove with: artifact-dir prune myproj--issue-7"
    assert_equals "0" "$RC" "exit status"
    assert_equals "$expected" "$OUT" "non-TTY output is the list plus the literal prune hint"
    assert_dir_exists "$S/cache/cargo/myproj--issue-7/debug" "cargo dir must survive a non-TTY run"
    assert_dir_exists "$S/cache/node/myproj--issue-7" "node dir must survive a non-TTY run"
}

test_no_hits_prints_nothing() {
    run_notty "$S/myproj" 7
    assert_equals "0" "$RC" "exit status"
    assert_equals "" "$OUT" "no matching dirs prints nothing"
}

# Another project's dirs and a longer issue number sharing the prefix are not
# issue-7's: never listed, never touched.
test_other_names_not_listed() {
    command mkdir -p "$S/cache/cargo/otherproj--issue-7" "$S/cache/cargo/myproj--issue-70"
    run_notty "$S/myproj" 7
    assert_equals "0" "$RC" "exit status"
    assert_equals "" "$OUT" "only <project>--issue-7 matches"
    assert_dir_exists "$S/cache/cargo/otherproj--issue-7" "other project's dir untouched"
    assert_dir_exists "$S/cache/cargo/myproj--issue-70" "issue-70's dir untouched"
}

# Outside any project, --project fails; the tail must still exit 0 silently.
test_outside_project_exits_zero() {
    seed_issue7
    run_notty "$S/nowhere" 7
    assert_equals "0" "$RC" "exit status"
    assert_equals "" "$OUT" "no project resolvable prints nothing"
    assert_dir_exists "$S/cache/cargo/myproj--issue-7" "nothing deleted"
}

# A broken artifact-dir is a failure path too: exit 0, never fail the teardown.
test_missing_artifact_dir_exits_zero() {
    seed_issue7
    RC=0
    OUT="$(cd "$S/myproj" && WORKTREE_PRUNE_ARTIFACT_DIR_BIN="$S/no-such-artifact-dir" \
        bash "$SCRIPT" 7 </dev/null 2>/dev/null)" || RC=$?
    assert_equals "0" "$RC" "exit status"
    assert_equals "" "$OUT" "unresolvable artifact-dir prints nothing"
}

test_invalid_n_exits_two() {
    run_notty "$S/myproj" '7;rm'
    assert_equals "2" "$RC" "non-numeric N is a caller error"
    run_notty "$S/myproj"
    assert_equals "2" "$RC" "missing N is a caller error"
}

test_tty_yes_prunes() {
    if ! command -v script >/dev/null 2>&1; then
        skip_test "util-linux script not installed — TTY path not exercised"
        return 0
    fi
    seed_issue7
    run_tty "$S/myproj" y
    assert_equals "0" "$RC" "exit status"
    assert_contains "$OUT" "Remove them? [y/N]" "TTY run prompts"
    assert_dir_not_exists "$S/cache/cargo/myproj--issue-7" "cargo dir removed on 'y'"
    assert_dir_not_exists "$S/cache/node/myproj--issue-7" "node dir removed on 'y'"
}

test_tty_no_keeps() {
    if ! command -v script >/dev/null 2>&1; then
        skip_test "util-linux script not installed — TTY path not exercised"
        return 0
    fi
    seed_issue7
    run_tty "$S/myproj" n
    assert_equals "0" "$RC" "exit status"
    assert_contains "$OUT" "kept — remove later with: artifact-dir prune myproj--issue-7" "'n' keeps and hints"
    assert_dir_exists "$S/cache/cargo/myproj--issue-7" "cargo dir kept on 'n'"
    assert_dir_exists "$S/cache/node/myproj--issue-7" "node dir kept on 'n'"
}

# The recipe must call this script, not an inline copy that could drift untested.
test_recipe_invokes_script() {
    if ! command -v just >/dev/null 2>&1; then
        skip_test "just not installed — recipe wiring not checked"
        return 0
    fi
    local shown
    shown="$(command just --justfile "$PROJECT_ROOT/justfile" --working-directory "$PROJECT_ROOT" \
        --show worktree-rm 2>&1)" || true
    assert_contains "$shown" '/bin/worktree-artifact-prune.sh" "$_n"' "worktree-rm runs the tested script"
    assert_not_contains "$shown" "prune \"\$_name\" --dry-run" "no inline copy of the tail left in the recipe"
}

# ---------------------------------------------------------------------------

run_test_with_setup test_notty_lists_and_deletes_nothing "Non-TTY lists dirs + prune hint, deletes nothing"
run_test_with_setup test_no_hits_prints_nothing "No matching dirs prints nothing, exits 0"
run_test_with_setup test_other_names_not_listed "Other project / issue-70 dirs are not listed or touched"
run_test_with_setup test_outside_project_exits_zero "Outside a project exits 0 silently"
run_test_with_setup test_missing_artifact_dir_exits_zero "Unresolvable artifact-dir exits 0 silently"
run_test_with_setup test_invalid_n_exits_two "Invalid N exits 2"
run_test_with_setup test_tty_yes_prunes "TTY 'y' prunes the dirs"
run_test_with_setup test_tty_no_keeps "TTY 'n' keeps the dirs and prints the hint"
run_test_with_setup test_recipe_invokes_script "worktree-rm recipe invokes the script"

generate_report
