#!/usr/bin/env bash
# Regression test for issue #599: init_test_framework must clear inherited git
# environment variables so fixture-building tests are hermetic under git hooks.
#
# git exports GIT_DIR / GIT_INDEX_FILE / GIT_WORK_TREE / GIT_COMMON_DIR /
# GIT_PREFIX into the environment of hooks it spawns (e.g. lefthook pre-push).
# A test that builds a throwaway repo with `git init` in a mktemp dir would then
# have that nested git command hijacked back at the REAL repo. The framework now
# unsets those vars once, centrally, in init_test_framework(). These tests prove
# the guard holds even when the suite is invoked from a polluted environment.
#
# The guard is exercised in a CHILD shell (not by calling init_test_framework in
# this process), because init_test_framework() resets the suite's pass/fail
# counters — re-running it mid-suite would corrupt this file's own report.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"
init_test_framework

FRAMEWORK_SH="$SCRIPT_DIR/../framework.sh"

test_suite "test framework git-env hermeticity (#599)"

# ---------------------------------------------------------------------------
# Run a fresh bash with a deliberately bogus git environment exported (as a hook
# would), source the framework, run init_test_framework, and emit the resulting
# state on stdout for the caller to assert against. Docker checks are skipped so
# the guard is tested in isolation from daemon availability.
# ---------------------------------------------------------------------------
run_in_polluted_env() {
    local body="$1"
    # FRAMEWORK_SH is passed through the environment (not interpolated into the
    # -c string) so a repo checked out under an apostrophe-containing path can't
    # break the quoting. The body is appended literally; the child shell does
    # the expansion of any $vars it contains.
    /usr/bin/env -i \
        PATH="$PATH" \
        HOME="${HOME:-/tmp}" \
        TERM="dumb" \
        SKIP_DOCKER_CHECK=true \
        FRAMEWORK_SH="$FRAMEWORK_SH" \
        GIT_DIR="/nonexistent/bogus/.git" \
        GIT_INDEX_FILE="/nonexistent/bogus/.git/index" \
        GIT_WORK_TREE="/nonexistent/bogus" \
        GIT_COMMON_DIR="/nonexistent/bogus/.git" \
        GIT_PREFIX="bogus/" \
        /bin/bash -c 'source "$FRAMEWORK_SH" >/dev/null 2>&1; init_test_framework >/dev/null 2>&1; '"$body"
}

# init_test_framework clears every inherited git env var.
test_clears_git_env_vars() {
    local out
    out=$(run_in_polluted_env '
        for v in GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR GIT_PREFIX; do
            if [ -n "${!v+x}" ]; then /usr/bin/echo "$v=SET"; else /usr/bin/echo "$v=unset"; fi
        done
    ')

    assert_contains "$out" "GIT_DIR=unset" "GIT_DIR should be cleared"
    assert_contains "$out" "GIT_INDEX_FILE=unset" "GIT_INDEX_FILE should be cleared"
    assert_contains "$out" "GIT_WORK_TREE=unset" "GIT_WORK_TREE should be cleared"
    assert_contains "$out" "GIT_COMMON_DIR=unset" "GIT_COMMON_DIR should be cleared"
    assert_contains "$out" "GIT_PREFIX=unset" "GIT_PREFIX should be cleared"
    assert_not_contains "$out" "=SET" "no git env var should survive init_test_framework"
}

# A fixture `git init` after init_test_framework lands in the temp dir, not the
# bogus inherited GIT_DIR — the real-world symptom the guard prevents.
test_fixture_git_init_is_hermetic() {
    local out
    out=$(run_in_polluted_env '
        tmp=$(/usr/bin/mktemp -d)
        cd "$tmp"
        /usr/bin/git init -q .
        # Resolve where git thinks the repo is; must be inside our temp dir,
        # never the bogus inherited GIT_DIR.
        gitdir=$(/usr/bin/git rev-parse --absolute-git-dir 2>/dev/null || /usr/bin/echo MISSING)
        /usr/bin/echo "gitdir=$gitdir"
        /usr/bin/echo "tmp=$tmp"
        [ -d "$tmp/.git" ] && /usr/bin/echo "dotgit=present" || /usr/bin/echo "dotgit=absent"
        /usr/bin/rm -rf "$tmp"
    ')

    assert_contains "$out" "dotgit=present" "git init should create .git in the temp fixture dir"
    assert_not_contains "$out" "gitdir=/nonexistent/bogus" "fixture must not bind to the inherited bogus GIT_DIR"
    assert_not_contains "$out" "gitdir=MISSING" "git init should produce a resolvable repo in the temp dir"

    # Positively assert the resolved gitdir is INSIDE the temp dir — not merely
    # "not the bogus path" — so a third unexpected location (e.g. $HOME/.git)
    # can't slip past the two negative assertions above.
    local tmpval
    tmpval=$(/usr/bin/grep '^tmp=' <<<"$out" | /usr/bin/cut -d= -f2)
    assert_not_empty "$tmpval" "the fixture body must report its temp dir"
    assert_contains "$out" "gitdir=$tmpval/.git" "fixture gitdir must resolve inside the temp dir"
}

run_test test_clears_git_env_vars "init_test_framework unsets inherited git env vars"
run_test test_fixture_git_init_is_hermetic "fixture git init lands in temp dir despite bogus GIT_DIR"

generate_report
