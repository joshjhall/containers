#!/usr/bin/env bash
# Tests for golem-notify.sh golem-id resolution (issue #587).
#
# Regression: the hook used to derive the golem id from `basename "$(pwd)"`,
# which produced a placeholder whenever the Notification hook fired with cwd
# outside the worktree root — a subdirectory, or a review-harness Workflow
# subagent with its own cwd. The fix derives the id from, in order:
#   1. $GOLEM_ID (stamped at launch — deterministic, cwd-independent)
#   2. the git WORKTREE-ROOT basename (issue-N -> golem-N), via
#      `git rev-parse --show-toplevel`, which is cwd-independent unlike `pwd`
#   3. the `primary` label when neither resolves — a non-golem interactive
#      session (human / orchestrator), not the old `golem-?` placeholder (#746)
#
# These tests build a real main checkout + linked worktree so both
# `git rev-parse --git-common-dir` (feed location) and `--show-toplevel`
# (worktree root) resolve exactly as they do for a live golem.

set -euo pipefail

# These tests create throwaway git repos + worktrees under /tmp. When the suite
# runs from a git hook (e.g. lefthook pre-push), git exports GIT_DIR /
# GIT_INDEX_FILE / GIT_WORK_TREE pointing at the REAL repo — those would hijack
# our `git init` / `git worktree add`. The inherited git env is now cleared
# centrally at framework.sh module scope (when it is sourced below), so no
# per-test unset is needed here. See issue #599.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../framework.sh"
init_test_framework

# The build-bound template copy migrated to the librarian workflow plugin (#611);
# only the host runtime copy at .claude/hooks/ remains in this repo, kept in sync
# from origin/main by sync-host.sh. Exercise that copy.
HOOK_REPO="$CONTAINERS_DIR/.claude/hooks/golem-notify.sh"

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
# Outside any worktree (plain repo whose root is not issue-*/golem-*) and no
# GOLEM_ID -> `primary`. A non-golem interactive session (human working in the
# main checkout, or an orchestrator) must not surface as the `golem-?`
# placeholder, which reads as a broken golem in the feed (#746).
# ===========================================================================
test_primary_outside_worktree() {
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
    assert_equals "primary" "$got" "primary when not in a worktree and no GOLEM_ID"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$main")"
}
run_test test_primary_outside_worktree "primary label when no GOLEM_ID and root is not issue-N (#746)"

# ===========================================================================
# Concurrent primary sessions (multiple shell tabs, same repo) must NOT collapse
# onto one `primary` feed row — `just golems` groups the feed by `.golem`, so
# each tab needs a distinct id. The hook differentiates them by the Notification
# payload's native session_id: `primary-<short>` (#746, AC2/AC3). Runs the hook
# in a plain repo with two different payload session_ids and checks the last two
# feed lines carry distinct, session-derived golem ids.
# ===========================================================================
# Like run_hook_golem but sends a caller-chosen payload session_id (no GOLEM_ID),
# echoing the golem id of the LAST feed line.
run_hook_primary_session() {
    local hook="$1" cwd="$2" session_id="$3"
    local feed
    (
        cd "$cwd"
        env -u GOLEM_ID "$hook" <<<"{\"message\":\"needs permission\",\"session_id\":\"$session_id\"}" >/dev/null 2>&1
    )
    feed="$(
        cd "$cwd"
        common_dir="$(/usr/bin/git rev-parse --git-common-dir)"
        case "$common_dir" in /*) ;; *) common_dir="$(/usr/bin/pwd)/$common_dir" ;; esac
        /usr/bin/echo "$(/usr/bin/dirname "$common_dir")/.worktrees/.status/feed.jsonl"
    )"
    /usr/bin/jq -r '.golem' "$feed" 2>/dev/null | /usr/bin/tail -1
}

test_concurrent_primary_sessions_distinct() {
    local main got_a got_b
    main=$(/usr/bin/mktemp -d)/plainrepo
    /usr/bin/mkdir -p "$main"
    (
        cd "$main"
        /usr/bin/git init -q .
        /usr/bin/git config user.email t@t.t
        /usr/bin/git config user.name t
        /usr/bin/git commit -q --allow-empty -m init
    )
    got_a=$(run_hook_primary_session "$HOOK_REPO" "$main" "aaaaaaaa11112222")
    got_b=$(run_hook_primary_session "$HOOK_REPO" "$main" "bbbbbbbb33334444")
    assert_equals "primary-aaaaaaaa" "$got_a" "tab one keyed by its session_id"
    assert_equals "primary-bbbbbbbb" "$got_b" "tab two keyed by its session_id"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$main")"
}
run_test test_concurrent_primary_sessions_distinct "concurrent primary tabs get distinct feed ids (#746)"

# ===========================================================================
# Orchestrator marker (#750). A session marked CLAUDE_SESSION_ROLE=orchestrator
# (no GOLEM_ID, not in a worktree) surfaces in the feed as `orchestrator-<short>`
# — feed parity with claude-host-event.sh (#746 AC3), so `just golems` lists the
# fleet coordinator as its own row instead of an indistinct `primary`. Like
# run_hook_primary_session but exports the orchestrator marker alongside the
# chosen payload session_id.
# ===========================================================================
run_hook_orch_session() {
    local hook="$1" cwd="$2" session_id="$3"
    local feed
    (
        cd "$cwd"
        env -u GOLEM_ID CLAUDE_SESSION_ROLE=orchestrator "$hook" \
            <<<"{\"message\":\"needs permission\",\"session_id\":\"$session_id\"}" >/dev/null 2>&1
    )
    feed="$(
        cd "$cwd"
        common_dir="$(/usr/bin/git rev-parse --git-common-dir)"
        case "$common_dir" in /*) ;; *) common_dir="$(/usr/bin/pwd)/$common_dir" ;; esac
        /usr/bin/echo "$(/usr/bin/dirname "$common_dir")/.worktrees/.status/feed.jsonl"
    )"
    /usr/bin/jq -r '.golem' "$feed" 2>/dev/null | /usr/bin/tail -1
}

test_orchestrator_feed_id() {
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
    got=$(run_hook_orch_session "$HOOK_REPO" "$main" "aaaaaaaa11112222")
    assert_equals "orchestrator-aaaaaaaa" "$got" "orchestrator marker -> orchestrator-<short> feed id"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$main")"
}
run_test test_orchestrator_feed_id "orchestrator marker surfaces as orchestrator-<short> in the feed (#750)"

# Two concurrent orchestrator tabs (different native session_ids) in the SAME
# plain repo get DISTINCT feed ids — the same anti-collision guarantee as
# primary (test_concurrent_primary_sessions_distinct). Without the per-tab
# session_id suffix both `/orchestrate` tabs would collapse onto one
# `orchestrator` feed row and clobber each other's gate state (gap 1 / #756).
test_concurrent_orchestrator_sessions_distinct() {
    local main got_a got_b
    main=$(/usr/bin/mktemp -d)/plainrepo
    /usr/bin/mkdir -p "$main"
    (
        cd "$main"
        /usr/bin/git init -q .
        /usr/bin/git config user.email t@t.t
        /usr/bin/git config user.name t
        /usr/bin/git commit -q --allow-empty -m init
    )
    got_a=$(run_hook_orch_session "$HOOK_REPO" "$main" "aaaaaaaa11112222")
    got_b=$(run_hook_orch_session "$HOOK_REPO" "$main" "bbbbbbbb33334444")
    assert_equals "orchestrator-aaaaaaaa" "$got_a" "orchestrator tab one keyed by its session_id"
    assert_equals "orchestrator-bbbbbbbb" "$got_b" "orchestrator tab two keyed by its session_id"
    if [ "$got_a" = "$got_b" ]; then
        fail_test "concurrent orchestrator sessions must not collide on one feed id"
    else
        pass_test
    fi
    /usr/bin/rm -rf "$(/usr/bin/dirname "$main")"
}
run_test test_concurrent_orchestrator_sessions_distinct "concurrent orchestrator tabs get distinct feed ids (#756)"

# The worktree-root arm outranks the marker: an issue-N worktree with the marker
# set is still `golem-N` (the marker only acts on the primary fallback).
test_worktree_root_outranks_orchestrator_marker() {
    local wt got
    wt=$(setup_worktree 707)
    got=$(run_hook_orch_session "$HOOK_REPO" "$wt" "aaaaaaaa11112222")
    assert_equals "golem-707" "$got" "worktree-root golem-N outranks the orchestrator marker"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$(/usr/bin/dirname "$wt")")"
}
run_test test_worktree_root_outranks_orchestrator_marker "worktree golem outranks orchestrator marker (#750)"

# ===========================================================================
# $GOLEM_ID outranks the orchestrator marker: a stamped golem with the marker
# also set is still keyed by its GOLEM_ID (the marker only acts on the primary
# fallback). This is golem-notify's arm of the precedence matrix that #750 left
# untested — host-event tests the symmetric GOLEM_ID-vs-marker case (gap 3 / #756).
# ===========================================================================
test_golem_id_outranks_orchestrator_marker() {
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
    # Env carries BOTH a valid GOLEM_ID and the orchestrator marker; GOLEM_ID wins.
    got=$(
        cd "$main"
        GOLEM_ID=golem-999 CLAUDE_SESSION_ROLE=orchestrator "$HOOK_REPO" \
            <<<'{"message":"needs permission","session_id":"aaaaaaaa11112222"}' >/dev/null 2>&1
        common_dir="$(/usr/bin/git rev-parse --git-common-dir)"
        case "$common_dir" in /*) ;; *) common_dir="$(/usr/bin/pwd)/$common_dir" ;; esac
        /usr/bin/jq -r '.golem' "$(/usr/bin/dirname "$common_dir")/.worktrees/.status/feed.jsonl" 2>/dev/null | /usr/bin/tail -1
    )
    assert_equals "golem-999" "$got" "GOLEM_ID outranks the orchestrator marker (marker only acts on the primary fallback)"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$main")"
}
run_test test_golem_id_outranks_orchestrator_marker "GOLEM_ID outranks orchestrator marker (#756)"

# ===========================================================================
# An unset marker — and, defensively, a non-`orchestrator` value — falls through
# to `primary`: the marker is fail-safe and never accidentally promotes a human
# session to `orchestrator`. Mirrors host-event's
# test_unmarked_or_unknown_role_is_primary (gap 2 / #756).
# ===========================================================================
test_unknown_role_is_primary() {
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
    # A non-orchestrator role value must NOT classify as orchestrator.
    got=$(
        cd "$main"
        env -u GOLEM_ID CLAUDE_SESSION_ROLE=something-else "$HOOK_REPO" \
            <<<'{"message":"needs permission","session_id":"aaaaaaaa11112222"}' >/dev/null 2>&1
        common_dir="$(/usr/bin/git rev-parse --git-common-dir)"
        case "$common_dir" in /*) ;; *) common_dir="$(/usr/bin/pwd)/$common_dir" ;; esac
        /usr/bin/jq -r '.golem' "$(/usr/bin/dirname "$common_dir")/.worktrees/.status/feed.jsonl" 2>/dev/null | /usr/bin/tail -1
    )
    assert_equals "primary-aaaaaaaa" "$got" "an unknown CLAUDE_SESSION_ROLE falls through to primary (fail-safe)"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$main")"
}
run_test test_unknown_role_is_primary "unknown CLAUDE_SESSION_ROLE falls through to primary (#756)"

# ===========================================================================
# A primary session whose Notification payload has NO session_id falls back to
# the bare `primary` id (still valid, just non-differentiated).
# ===========================================================================
test_primary_bare_without_session_id() {
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
    # run_hook_golem sends a payload with no session_id field.
    got=$(run_hook_golem "$HOOK_REPO" "$main" "")
    assert_equals "primary" "$got" "bare primary when payload carries no session_id"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$main")"
}
run_test test_primary_bare_without_session_id "primary without session_id stays bare (#746)"

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
# Event classification (#600): map the Notification message to an event kind so
# the reader can tell a real permission gate from a transient idle. Runs the
# hook with a chosen message and echoes the `.event` of the LAST feed line.
# Args: <hook> <cwd> <message>
# ===========================================================================
run_hook_event() {
    local hook="$1" cwd="$2" message="$3"
    local feed
    (
        cd "$cwd"
        GOLEM_ID="golem-x" "$hook" <<<"{\"message\":\"$message\"}" >/dev/null 2>&1
    )
    feed="$(
        cd "$cwd"
        common_dir="$(/usr/bin/git rev-parse --git-common-dir)"
        case "$common_dir" in /*) ;; *) common_dir="$(/usr/bin/pwd)/$common_dir" ;; esac
        /usr/bin/echo "$(/usr/bin/dirname "$common_dir")/.worktrees/.status/feed.jsonl"
    )"
    /usr/bin/jq -r '.event' "$feed" 2>/dev/null | /usr/bin/tail -1
}

test_permission_message_is_gate() {
    local wt got
    wt=$(setup_worktree 710)
    got=$(run_hook_event "$HOOK_REPO" "$wt" "Claude needs your permission to use Bash")
    assert_equals "gate" "$got" "a permission-decision message classifies as gate"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$(/usr/bin/dirname "$wt")")"
}
run_test test_permission_message_is_gate "permission message classifies as event=gate (#600)"

test_waiting_for_input_is_idle() {
    local wt got
    wt=$(setup_worktree 711)
    got=$(run_hook_event "$HOOK_REPO" "$wt" "Claude is waiting for your input")
    assert_equals "idle" "$got" "the transient idle message classifies as idle"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$(/usr/bin/dirname "$wt")")"
}
run_test test_waiting_for_input_is_idle "'waiting for your input' classifies as event=idle (#600)"

test_classification_case_insensitive() {
    local wt got
    wt=$(setup_worktree 712)
    got=$(run_hook_event "$HOOK_REPO" "$wt" "CLAUDE IS WAITING FOR YOUR INPUT")
    assert_equals "idle" "$got" "idle classification is case-insensitive"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$(/usr/bin/dirname "$wt")")"
}
run_test test_classification_case_insensitive "idle classification is case-insensitive (#600)"

test_unknown_message_defaults_to_gate() {
    local wt got
    wt=$(setup_worktree 713)
    got=$(run_hook_event "$HOOK_REPO" "$wt" "some unrecognized notification")
    assert_equals "gate" "$got" "an unrecognized message defaults to gate (fail loud)"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$(/usr/bin/dirname "$wt")")"
}
run_test test_unknown_message_defaults_to_gate "unrecognized message defaults to event=gate (#600)"

# ===========================================================================
# Cross-hook label agreement (gap 4 / #756). #750's "both hooks agree" AC was
# only satisfied by matching hardcoded literals across the two test files —
# nothing drove BOTH hooks with identical input and diffed the resulting label.
# This test does exactly that: one plain repo, identical env (the orchestrator
# marker) and identical payload session_id fed to both hooks, then asserts the
# host-event POST key is the golem-notify feed id with the `<project>-` prefix.
#
# golem-notify emits `.golem` = `<role>-<short>` (no project prefix — the feed is
# already per-repo); claude-host-event POSTs `.session_id` = `<project>-<role>-<short>`
# (the host bridge keys globally, so it needs the project). Agreement therefore
# means: host_event_session_id == "<project>-" + golem_notify_golem.
# ===========================================================================
HOOK_HOST_EVENT="$CONTAINERS_DIR/lib/features/templates/claude/hooks/claude-host-event.sh"

test_cross_hook_label_agreement() {
    local main proj stubdir capture role_env
    main=$(/usr/bin/mktemp -d)/plainrepo
    /usr/bin/mkdir -p "$main"
    (
        cd "$main"
        /usr/bin/git init -q .
        /usr/bin/git config user.email t@t.t
        /usr/bin/git config user.name t
        /usr/bin/git commit -q --allow-empty -m init
    )
    proj=$(/usr/bin/basename "$main")

    # Identical input for both hooks: the orchestrator marker + one session_id.
    role_env="orchestrator"
    local session_id="aaaaaaaa11112222"

    # 1. golem-notify -> read `.golem` from its feed.
    local golem_id
    golem_id=$(
        cd "$main"
        env -u GOLEM_ID CLAUDE_SESSION_ROLE="$role_env" "$HOOK_REPO" \
            <<<"{\"message\":\"needs permission\",\"session_id\":\"$session_id\"}" >/dev/null 2>&1
        common_dir="$(/usr/bin/git rev-parse --git-common-dir)"
        case "$common_dir" in /*) ;; *) common_dir="$(/usr/bin/pwd)/$common_dir" ;; esac
        /usr/bin/jq -r '.golem' "$(/usr/bin/dirname "$common_dir")/.worktrees/.status/feed.jsonl" 2>/dev/null | /usr/bin/tail -1
    )

    # 2. claude-host-event -> capture the POST `.session_id` via a curl stub that
    #    records --data-raw. STATE=Ended makes the POST synchronous (non-terminal
    #    states background the curl and would race the capture read).
    stubdir=$(/usr/bin/mktemp -d)
    capture="$stubdir/body.json"
    /usr/bin/cat >"$stubdir/curl" <<'STUB'
#!/usr/bin/env bash
prev=""
for a in "$@"; do
    if [ "$prev" = "--data-raw" ]; then /usr/bin/printf '%s' "$a" >"$CAPTURE"; break; fi
    prev="$a"
done
exit 0
STUB
    /usr/bin/chmod +x "$stubdir/curl"
    local host_sid
    host_sid=$(
        cd "$main"
        # Clear BASH_ENV so /etc/bash_env can't rebuild PATH and re-shadow the
        # stub curl with the real one (see #618). Scrub GOLEM_ID/AGENT_ID so only
        # the orchestrator marker classifies this session.
        env -u GOLEM_ID -u AGENT_ID -u BASH_ENV \
            CAPTURE="$capture" PATH="$stubdir:$PATH" \
            NOTCHBAR_AGENTS_HOST=127.0.0.1 NOTCHBAR_AGENTS_PORT=59990 \
            CLAUDE_SESSION_ROLE="$role_env" \
            "$HOOK_HOST_EVENT" Ended \
            <<<"{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"$session_id\"}" >/dev/null 2>&1
        /usr/bin/jq -r '.session_id' "$capture" 2>/dev/null
    )

    # Sanity: both hooks resolved a non-empty label for identical input.
    assert_equals "orchestrator-aaaaaaaa" "$golem_id" "golem-notify feed id for the shared input"
    assert_equals "${proj}-orchestrator-aaaaaaaa" "$host_sid" "host-event POST key for the shared input"
    # The core agreement assertion: host-event key == "<project>-" + feed id.
    assert_equals "${proj}-${golem_id}" "$host_sid" "both hooks classify identical input to the same label"

    /usr/bin/rm -rf "$stubdir" "$(/usr/bin/dirname "$main")"
}
run_test test_cross_hook_label_agreement "both hooks agree on the label for identical input (#756)"

# ===========================================================================
# Generate report
# ===========================================================================
generate_report
