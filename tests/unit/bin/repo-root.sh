#!/usr/bin/env bash
# Unit tests for bin/repo-root.sh — bare-repo-safe repository root resolution.
#
# Regression coverage for #604: the worktree/golem `just` recipes resolved the
# repo root with `git rev-parse --show-toplevel`, which aborts (exit 128) when
# the repo ROOT is bare (the worktree-host layout). repo-root.sh resolves the
# main checkout from the git common dir instead, which works in a bare host, a
# worktree, and a normal checkout alike.

set -euo pipefail

# Hermetic git environment. A pushing git hook exports GIT_DIR / GIT_INDEX_FILE
# etc. into this test's environment; left set, they hijack the fixtures' nested
# git commands back at the real repo (see #599). Clear them before any fixture
# git runs. (Once #599 lands this is redundant with the framework guard, but it
# keeps this test correct standalone meanwhile.)
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR GIT_PREFIX

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

init_test_framework

test_suite "repo-root.sh — bare-safe root resolution"

REPO_ROOT_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/bin/repo-root.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
}

teardown() {
    if [ -n "${TEST_DIR:-}" ] && [ -d "$TEST_DIR" ]; then
        command rm -rf "$TEST_DIR"
    fi
}

# Helper: realpath that tolerates /tmp -> /private/tmp style symlinks (macOS).
canon() { cd "$1" 2>/dev/null && pwd -P; }

# ---------------------------------------------------------------------------
# 1. Normal (non-bare) checkout: resolves to the work tree, matching
#    --show-toplevel.
# ---------------------------------------------------------------------------
test_normal_checkout() {
    setup
    local repo="$TEST_DIR/normal"
    command mkdir -p "$repo"
    (cd "$repo" && git init -q && git commit -q --allow-empty -m init)

    local got
    got="$(cd "$repo" && bash "$REPO_ROOT_SCRIPT")"

    assert_equals "$(canon "$repo")" "$(canon "$got")" \
        "repo-root resolves a normal checkout to its work tree"
    teardown
}

# ---------------------------------------------------------------------------
# 2. Bare repo host: --show-toplevel would abort; repo-root must succeed and
#    return the directory CONTAINING the bare .git-equivalent.
#    Model the real host layout: <root>/ is a work tree whose .git is a FILE-
#    free bare-style dir. Simplest faithful model: a bare repo at <root>/.git
#    by initialising bare into a `.git` subdir of <root> and confirming
#    repo-root returns <root>.
# ---------------------------------------------------------------------------
test_bare_host() {
    setup
    local root="$TEST_DIR/host"
    command mkdir -p "$root/.git"
    (cd "$root/.git" && git init -q --bare)

    # From inside the bare dir, --show-toplevel aborts (sanity-check the premise).
    local rc=0
    (cd "$root/.git" && git rev-parse --show-toplevel >/dev/null 2>&1) || rc=$?
    assert_not_equals "0" "$rc" \
        "premise: --show-toplevel fails inside a bare repo"

    local got
    got="$(cd "$root/.git" && bash "$REPO_ROOT_SCRIPT")"
    assert_equals "$(canon "$root")" "$(canon "$got")" \
        "repo-root resolves bare host to the dir containing .git"
    teardown
}

# ---------------------------------------------------------------------------
# 3. From inside a linked worktree: repo-root returns the MAIN checkout root
#    (worktrees share the common dir), not the worktree path — which is what
#    the recipes need (they operate on <main>/.worktrees/...).
# ---------------------------------------------------------------------------
test_from_worktree() {
    setup
    local main="$TEST_DIR/main"
    command mkdir -p "$main"
    (cd "$main" && git init -q && git commit -q --allow-empty -m init)
    (cd "$main" && git worktree add -q "$TEST_DIR/wt" -b wt-branch >/dev/null 2>&1)

    local got
    got="$(cd "$TEST_DIR/wt" && bash "$REPO_ROOT_SCRIPT")"
    assert_equals "$(canon "$main")" "$(canon "$got")" \
        "repo-root returns the main checkout root from inside a worktree"
    teardown
}

# ---------------------------------------------------------------------------
# 4. Outside any git repo: exit non-zero, print nothing on stdout.
# ---------------------------------------------------------------------------
test_outside_repo() {
    setup
    local out rc=0
    out="$(cd "$TEST_DIR" && bash "$REPO_ROOT_SCRIPT" 2>/dev/null)" || rc=$?
    assert_not_equals "0" "$rc" "repo-root exits non-zero outside a git repo"
    assert_equals "" "$out" "repo-root prints nothing on stdout outside a repo"
    teardown
}

run_test test_normal_checkout
run_test test_bare_host
run_test test_from_worktree
run_test test_outside_repo

generate_report
