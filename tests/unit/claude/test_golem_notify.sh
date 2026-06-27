#!/usr/bin/env bash
# Tests for golem-notify.sh golem-id resolution (issue #587).
#
# Regression: the hook used to derive the golem id from `basename "$(pwd)"`,
# which produced the `golem-?` placeholder whenever the Notification hook fired
# with cwd outside the worktree root — a subdirectory, or a review-harness
# Workflow subagent with its own cwd. The fix derives the id from, in order:
#   1. $GOLEM_ID (stamped at launch — deterministic, cwd-independent)
#   2. the git WORKTREE-ROOT basename (issue-N -> golem-N), via
#      `git rev-parse --show-toplevel`, which is cwd-independent unlike `pwd`
#   3. the `golem-?` placeholder only when neither resolves
#
# These tests build a real main checkout + linked worktree so both
# `git rev-parse --git-common-dir` (feed location) and `--show-toplevel`
# (worktree root) resolve exactly as they do for a live golem.

set -euo pipefail

# These tests create throwaway git repos + worktrees under /tmp. When the suite
# runs from a git hook (e.g. lefthook pre-push), git exports GIT_DIR /
# GIT_INDEX_FILE / GIT_WORK_TREE pointing at the REAL repo — those would hijack
# our `git init` / `git worktree add`, so the temp repos silently aren't created
# and the hook resolves the wrong worktree root. Drop the inherited git env up
# front so every `git` call below operates on the temp repo it's standing in.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR GIT_PREFIX

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../framework.sh"
init_test_framework

# Both copies must behave identically; exercise both.
HOOK_REPO="$CONTAINERS_DIR/.claude/hooks/golem-notify.sh"
HOOK_TEMPLATE="$CONTAINERS_DIR/lib/features/templates/claude/hooks/golem-notify.sh"

test_suite "golem-notify.sh id resolution (#587)"

# ---------------------------------------------------------------------------
# Build a main checkout with a linked `.worktrees/issue-<N>` worktree, mirroring
# the real golem layout. Echoes the worktree path on stdout. The feed lands at
# <main>/.worktrees/.status/feed.jsonl (resolved via the shared git-common-dir).
# ---------------------------------------------------------------------------
setup_worktree() {
    local n="$1"
    local main wt
    main=$(/usr/bin/mktemp -d)
    (
        cd "$main"
        /usr/bin/git init -q .
        /usr/bin/git config user.email t@t.t
        /usr/bin/git config user.name t
        /usr/bin/git commit -q --allow-empty -m init
        /usr/bin/git worktree add -q ".worktrees/issue-${n}" -b "feature/issue-${n}" >/dev/null 2>&1
    )
    /usr/bin/echo "$main/.worktrees/issue-${n}"
}

# Run the hook with a given cwd and environment, then echo the golem id of the
# LAST feed line. Args: <hook> <cwd> <golem_id_or_empty>
run_hook_golem() {
    local hook="$1" cwd="$2" golem_id="${3:-}"
    local feed
    (
        cd "$cwd"
        if [ -n "$golem_id" ]; then
            GOLEM_ID="$golem_id" "$hook" <<<'{"message":"needs permission"}' >/dev/null 2>&1
        else
            env -u GOLEM_ID "$hook" <<<'{"message":"needs permission"}' >/dev/null 2>&1
        fi
    )
    # Feed lives under the main checkout. Resolve the git-common-dir the same
    # way the hook does — it may be relative (plain repo: `.git`) or absolute
    # (linked worktree) — so the path is correct in both layouts.
    feed="$(
        cd "$cwd"
        common_dir="$(/usr/bin/git rev-parse --git-common-dir)"
        case "$common_dir" in /*) ;; *) common_dir="$(/usr/bin/pwd)/$common_dir" ;; esac
        /usr/bin/echo "$(/usr/bin/dirname "$common_dir")/.worktrees/.status/feed.jsonl"
    )"
    /usr/bin/jq -r '.golem' "$feed" 2>/dev/null | /usr/bin/tail -1
}

# ===========================================================================
# cwd at worktree root -> golem-N  (baseline; the path that always worked)
# ===========================================================================
test_root_cwd() {
    local wt got
    wt=$(setup_worktree 700)
    got=$(run_hook_golem "$HOOK_REPO" "$wt" "")
    assert_equals "golem-700" "$got" "id from worktree root"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$(/usr/bin/dirname "$wt")")"
}
run_test test_root_cwd "cwd at worktree root resolves golem-N"

# ===========================================================================
# cwd in a SUBDIRECTORY of the worktree -> still golem-N (the #587 regression:
# bare `pwd` basename here was the subdir name -> golem-?)
# ===========================================================================
test_subdir_cwd() {
    local wt sub got
    wt=$(setup_worktree 701)
    sub="$wt/crates/luggage/src"
    /usr/bin/mkdir -p "$sub"
    got=$(run_hook_golem "$HOOK_REPO" "$sub" "")
    assert_equals "golem-701" "$got" "id from worktree subdirectory (#587)"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$(/usr/bin/dirname "$wt")")"
}
run_test test_subdir_cwd "cwd in a subdirectory still resolves golem-N (#587)"

# ===========================================================================
# Deeply nested cwd (subagent-style) -> still golem-N
# ===========================================================================
test_deep_nested_cwd() {
    local wt deep got
    wt=$(setup_worktree 702)
    deep="$wt/a/b/c/d/e"
    /usr/bin/mkdir -p "$deep"
    got=$(run_hook_golem "$HOOK_REPO" "$deep" "")
    assert_equals "golem-702" "$got" "id from deep nested cwd"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$(/usr/bin/dirname "$wt")")"
}
run_test test_deep_nested_cwd "cwd deeply nested still resolves golem-N"

# ===========================================================================
# $GOLEM_ID takes precedence and wins even from a subdirectory
# ===========================================================================
test_golem_id_env_wins() {
    local wt sub got
    wt=$(setup_worktree 703)
    sub="$wt/deep/dir"
    /usr/bin/mkdir -p "$sub"
    # Env says 999 even though the worktree is issue-703 — env must win.
    got=$(run_hook_golem "$HOOK_REPO" "$sub" "golem-999")
    assert_equals "golem-999" "$got" "GOLEM_ID env is the authoritative source"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$(/usr/bin/dirname "$wt")")"
}
run_test test_golem_id_env_wins "GOLEM_ID env takes precedence over worktree path"

# ===========================================================================
# A malformed GOLEM_ID (not golem-*) is ignored; falls back to worktree root
# ===========================================================================
test_bad_golem_id_falls_back() {
    local wt got
    wt=$(setup_worktree 704)
    got=$(run_hook_golem "$HOOK_REPO" "$wt" "garbage")
    assert_equals "golem-704" "$got" "malformed GOLEM_ID is ignored, falls back to worktree root"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$(/usr/bin/dirname "$wt")")"
}
run_test test_bad_golem_id_falls_back "malformed GOLEM_ID falls back to worktree root"

# ===========================================================================
# Template copy behaves identically (the two files must stay in sync)
# ===========================================================================
test_template_copy_matches() {
    local wt sub got
    wt=$(setup_worktree 705)
    sub="$wt/nested"
    /usr/bin/mkdir -p "$sub"
    got=$(run_hook_golem "$HOOK_TEMPLATE" "$sub" "")
    assert_equals "golem-705" "$got" "template hook resolves id from subdirectory too"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$(/usr/bin/dirname "$wt")")"
}
run_test test_template_copy_matches "template copy resolves golem-N from subdirectory"

# ===========================================================================
# Outside any worktree (plain repo whose root is not issue-*/golem-*) and no
# GOLEM_ID -> the placeholder. Documents the one case that still yields golem-?.
# ===========================================================================
test_placeholder_outside_worktree() {
    local main got
    main=$(/usr/bin/mktemp -d)/plainrepo
    /usr/bin/mkdir -p "$main"
    (
        cd "$main"
        /usr/bin/git init -q .
        /usr/bin/git config user.email t@t.t
        /usr/bin/git config user.name t
        /usr/bin/git commit -q --allow-empty -m init
    )
    got=$(run_hook_golem "$HOOK_REPO" "$main" "")
    assert_equals "golem-?" "$got" "placeholder when not in a worktree and no GOLEM_ID"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$main")"
}
run_test test_placeholder_outside_worktree "placeholder only when no GOLEM_ID and root is not issue-N"

# ===========================================================================
# jq-absent printf fallback emits VALID JSON, even when the golem id carries
# JSON-breaking characters. Exercises the hand-rolled sanitize-and-escape path.
#
# Reaching the else-branch requires jq to be ABSENT from PATH — `command -v jq`
# tests for existence, not exit status, so a stub that merely exits non-zero
# would still be "found" and the jq branch would run. We instead build a
# minimal PATH containing only symlinks to `bash` (the hook's `env bash`
# shebang) and `git` (the only other PATH-resolved command) — no jq — and run
# the hook under `env -i` so nothing leaks the real PATH back in.
#
# On this path jq never parses the payload, so `.message` stays the default
# literal; the attacker-controlled value that actually flows into the feed is
# the golem id (from GOLEM_ID, which matches `golem-*` but whose suffix is
# otherwise unconstrained). Drive the injection through GOLEM_ID accordingly.
# ===========================================================================
test_jq_absent_fallback_valid_json() {
    local wt stubdir feed line
    wt=$(setup_worktree 706)

    stubdir=$(/usr/bin/mktemp -d)
    /usr/bin/ln -s "$(command -v bash)" "$stubdir/bash"
    /usr/bin/ln -s "$(command -v git)" "$stubdir/git"

    # GOLEM_ID matches golem-* but smuggles a quote (to break out of the JSON
    # string), a fake "x" key, and a backslash — exactly what the sanitizer
    # must neutralize.
    (
        cd "$wt"
        /usr/bin/env -i PATH="$stubdir" \
            GOLEM_ID='golem-706" ,"x":1 \evil' \
            "$HOOK_REPO" <<<'{}' >/dev/null 2>&1
    )

    feed="$(
        cd "$wt"
        common_dir="$(/usr/bin/git rev-parse --git-common-dir)"
        case "$common_dir" in /*) ;; *) common_dir="$(/usr/bin/pwd)/$common_dir" ;; esac
        /usr/bin/echo "$(/usr/bin/dirname "$common_dir")/.worktrees/.status/feed.jsonl"
    )"
    line="$(/usr/bin/tail -1 "$feed")"

    # The line must be valid JSON (sanitization worked) with no injected key,
    # and the golem prefix must survive (suffix sanitized, prefix intact).
    # `has("x")` doubles as the validity check: jq errors (empty output) on a
    # malformed line, so the equality below fails if the JSON is broken — no
    # separate pass_test/fail_test, which would double-count against the two
    # assertions that follow.
    local injected golem
    injected="$(/usr/bin/printf '%s' "$line" | /usr/bin/jq 'has("x")' 2>/dev/null)"
    assert_equals "false" "$injected" "fallback emits valid JSON with no GOLEM_ID-injected key"
    golem="$(/usr/bin/printf '%s' "$line" | /usr/bin/jq -r '.golem' 2>/dev/null)"
    assert_starts_with "$golem" "golem-706" "fallback preserves the golem id prefix"

    /usr/bin/rm -rf "$stubdir" "$(/usr/bin/dirname "$(/usr/bin/dirname "$wt")")"
}
run_test test_jq_absent_fallback_valid_json "jq-absent fallback emits valid JSON for an injection-laden GOLEM_ID"

# ===========================================================================
# A worktree whose root is already named `golem-N` (not `issue-N`) is taken
# verbatim — exercises the `golem-*` arm of the basename case (vs `golem-golem-N`).
# ===========================================================================
test_golem_named_worktree_verbatim() {
    local main wt got
    main=$(/usr/bin/mktemp -d)
    (
        cd "$main"
        /usr/bin/git init -q .
        /usr/bin/git config user.email t@t.t
        /usr/bin/git config user.name t
        /usr/bin/git commit -q --allow-empty -m init
        /usr/bin/git worktree add -q ".worktrees/golem-42" -b "feature/golem-42" >/dev/null 2>&1
    )
    wt="$main/.worktrees/golem-42"
    got=$(run_hook_golem "$HOOK_REPO" "$wt" "")
    assert_equals "golem-42" "$got" "golem-named worktree is used verbatim, not golem-golem-42"
    /usr/bin/rm -rf "$main"
}
run_test test_golem_named_worktree_verbatim "golem-named worktree root resolves verbatim"

# ===========================================================================
# Generate report
# ===========================================================================
generate_report
