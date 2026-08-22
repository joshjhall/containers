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
            env -u GOLEM_ID -u AGENT_ID "$hook" <<<'{"message":"needs permission"}' >/dev/null 2>&1
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
        env -u GOLEM_ID -u AGENT_ID "$hook" <<<"{\"message\":\"needs permission\",\"session_id\":\"$session_id\"}" >/dev/null 2>&1
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
        env -u GOLEM_ID -u AGENT_ID CLAUDE_SESSION_ROLE=orchestrator "$hook" \
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
        env -u GOLEM_ID -u AGENT_ID CLAUDE_SESSION_ROLE=something-else "$HOOK_REPO" \
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
# $AGENT_ID resolution arm (#766). A CONTAINER golem is identified only by
# $AGENT_ID (agentNN, from agent-entrypoint.sh) when it carries no $GOLEM_ID and
# its cwd is not an issue-*/golem-* worktree root — the non-pipeline interactive
# branch of that script, which returns before the #758 GOLEM_ID stamp.
#
# This hook used to have NO such arm, so that session fell through to
# `primary-<short>` here while claude-host-event.sh keyed it `<project>-agentNN`
# — a real cross-hook divergence, despite host-event's comment asserting the two
# ladders match. The arm closes it; these tests lock in both the arm itself and
# its position in the precedence ladder (below GOLEM_ID and the worktree root,
# above the orchestrator marker and primary).
#
# Runs the hook with a caller-chosen set of `KEY=VAL` env pairs (GOLEM_ID always
# scrubbed unless the caller passes one), echoing the golem id of the LAST feed
# line. Generalizes run_hook_orch_session, which is the same shape with the
# marker hardcoded. Args: <hook> <cwd> <session_id> [KEY=VAL ...]
# ===========================================================================
run_hook_env() {
    local hook="$1" cwd="$2" session_id="$3"
    shift 3
    local feed
    (
        cd "$cwd"
        env -u GOLEM_ID -u AGENT_ID -u CLAUDE_SESSION_ROLE "$@" "$hook" \
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

# Make a plain (non-worktree) repo whose root is neither issue-* nor golem-*, so
# resolution reaches the fallback arms. Echoes the repo path.
setup_plain_repo() {
    local main
    main=$(/usr/bin/mktemp -d)/plainrepo
    /usr/bin/mkdir -p "$main"
    (
        cd "$main"
        /usr/bin/git init -q .
        /usr/bin/git config user.email t@t.t
        /usr/bin/git config user.name t
        /usr/bin/git commit -q --allow-empty -m init
    )
    /usr/bin/echo "$main"
}

# $AGENT_ID resolves BEFORE the primary fallback, and is keyed BARE — no
# `-<short>` session_id suffix, unlike primary/orchestrator. The suffix exists
# only to separate roles that have no stable unique id; $AGENT_ID already is one
# (like $GOLEM_ID), and keeping it bare is what makes the feed id line up with
# host-event's `<project>-<golem>` POST key. Mirrors host-event's
# test_agent_id_before_primary (#746/#766).
test_agent_id_before_primary() {
    local main got
    main=$(setup_plain_repo)
    got=$(run_hook_env "$HOOK_REPO" "$main" "aaaaaaaa11112222" AGENT_ID=agent07)
    assert_equals "agent07" "$got" "AGENT_ID resolves before primary, keyed bare (no session_id suffix)"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$main")"
}
run_test test_agent_id_before_primary "AGENT_ID (container golem) resolves before primary (#766)"

# $AGENT_ID outranks the orchestrator marker — a container golem IS a golem and
# must not be reclassified as the fleet coordinator just because the marker is
# also set. Mirrors host-event's test_agent_id_outranks_orchestrator_marker.
test_agent_id_outranks_orchestrator_marker() {
    local main got
    main=$(setup_plain_repo)
    got=$(run_hook_env "$HOOK_REPO" "$main" "aaaaaaaa11112222" \
        AGENT_ID=agent07 CLAUDE_SESSION_ROLE=orchestrator)
    assert_equals "agent07" "$got" "AGENT_ID outranks the orchestrator marker (marker only acts on the primary fallback)"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$main")"
}
run_test test_agent_id_outranks_orchestrator_marker "AGENT_ID outranks orchestrator marker (#766)"

# Rung 1 > rung 3: a stamped $GOLEM_ID wins over $AGENT_ID. Both are set on a
# container golem taking the #758 pipeline path, where the issue-attributable
# golem-N is the id that belongs in the feed.
test_golem_id_outranks_agent_id() {
    local main got
    main=$(setup_plain_repo)
    got=$(run_hook_env "$HOOK_REPO" "$main" "aaaaaaaa11112222" \
        GOLEM_ID=golem-999 AGENT_ID=agent07)
    assert_equals "golem-999" "$got" "GOLEM_ID outranks AGENT_ID (#758 stamps both on the pipeline path)"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$main")"
}
run_test test_golem_id_outranks_agent_id "GOLEM_ID outranks AGENT_ID (#766)"

# Rung 2 > rung 3: the worktree-root basename wins over $AGENT_ID, so a golem
# working inside .worktrees/issue-N is golem-N even when the container also
# exports an agentNN id.
test_worktree_root_outranks_agent_id() {
    local wt got
    wt=$(setup_worktree 766)
    got=$(run_hook_env "$HOOK_REPO" "$wt" "aaaaaaaa11112222" AGENT_ID=agent07)
    assert_equals "golem-766" "$got" "worktree-root golem-N outranks AGENT_ID"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$(/usr/bin/dirname "$wt")")"
}
run_test test_worktree_root_outranks_agent_id "worktree root outranks AGENT_ID (#766)"

# An EMPTY $AGENT_ID must fall through, not key the feed on "". This is what the
# `?*` guard buys over a bare `*`; an empty golem field would group every such
# session onto one nameless feed row.
test_empty_agent_id_falls_through() {
    local main got
    main=$(setup_plain_repo)
    got=$(run_hook_env "$HOOK_REPO" "$main" "aaaaaaaa11112222" AGENT_ID=)
    assert_equals "primary-aaaaaaaa" "$got" "an empty AGENT_ID falls through to primary, never keys the feed on \"\""
    /usr/bin/rm -rf "$(/usr/bin/dirname "$main")"
}
run_test test_empty_agent_id_falls_through "empty AGENT_ID falls through to primary (#766)"

# $AGENT_ID is UNVALIDATED — only $GOLEM_ID is regex-gated — so on the jq-absent
# path it reaches the hand-rolled JSON as an untrusted string. A quote-laden
# AGENT_ID must be sanitized, not break out of the string literal and inject a
# key. Mirrors host-event's test_python_absent_fallback_sanitizes_injection.
test_jq_absent_sanitizes_agent_id() {
    local main stubdir feed line injected
    main=$(setup_plain_repo)

    # A PATH with only bash+git: no jq, so the hand-rolled fallback runs. env -i
    # also drops BASH_ENV, which would otherwise rebuild PATH on non-interactive
    # bash and re-shadow the stub with the real jq (#618).
    stubdir=$(/usr/bin/mktemp -d)
    /usr/bin/ln -s "$(command -v bash)" "$stubdir/bash"
    /usr/bin/ln -s "$(command -v git)" "$stubdir/git"

    (
        cd "$main"
        /usr/bin/env -i PATH="$stubdir" \
            AGENT_ID='agent07" ,"x":1 \evil' \
            "$HOOK_REPO" <<<'{}' >/dev/null 2>&1
    )

    feed="$(
        cd "$main"
        common_dir="$(/usr/bin/git rev-parse --git-common-dir)"
        case "$common_dir" in /*) ;; *) common_dir="$(/usr/bin/pwd)/$common_dir" ;; esac
        /usr/bin/echo "$(/usr/bin/dirname "$common_dir")/.worktrees/.status/feed.jsonl"
    )"
    line="$(/usr/bin/tail -1 "$feed")"

    # `has("x")` doubles as the validity check: jq errors (empty output) on a
    # malformed line, so the equality fails if the sanitizer let the JSON break.
    injected="$(/usr/bin/printf '%s' "$line" | /usr/bin/jq 'has("x")' 2>/dev/null)"
    assert_equals "false" "$injected" "jq-absent fallback sanitizes AGENT_ID: valid JSON, no injected key"

    /usr/bin/rm -rf "$stubdir" "$(/usr/bin/dirname "$main")"
}
run_test test_jq_absent_sanitizes_agent_id "jq-absent fallback sanitizes an injection-laden AGENT_ID (#766)"

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
# Build a main checkout with a linked worktree whose root is already named
# `golem-<N>` (not `issue-<N>`), so resolution takes the `golem-*` arm of the
# basename case rather than the `issue-*` one. Echoes the worktree path; the
# main checkout to clean up is two levels above it, as with setup_worktree.
# ===========================================================================
setup_golem_worktree() {
    local n="$1"
    local main
    main=$(/usr/bin/mktemp -d)
    (
        cd "$main"
        /usr/bin/git init -q .
        /usr/bin/git config user.email t@t.t
        /usr/bin/git config user.name t
        /usr/bin/git commit -q --allow-empty -m init
        /usr/bin/git worktree add -q ".worktrees/golem-${n}" -b "feature/golem-${n}" >/dev/null 2>&1
    )
    /usr/bin/echo "$main/.worktrees/golem-${n}"
}

# ===========================================================================
# A worktree whose root is already named `golem-N` (not `issue-N`) is taken
# verbatim — exercises the `golem-*` arm of the basename case (vs `golem-golem-N`).
# ===========================================================================
test_golem_named_worktree_verbatim() {
    local wt got
    wt=$(setup_golem_worktree 42)
    got=$(run_hook_golem "$HOOK_REPO" "$wt" "")
    assert_equals "golem-42" "$got" "golem-named worktree is used verbatim, not golem-golem-42"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$(/usr/bin/dirname "$wt")")"
}
run_test test_golem_named_worktree_verbatim "golem-named worktree root resolves verbatim"

# Rung 2 > rung 3, via the OTHER basename arm. test_worktree_root_outranks_agent_id
# covers the same precedence through `issue-*` only; `golem-*` is a distinct
# pattern branch of the outer case and must outrank $AGENT_ID just as `issue-*`
# does. Without this, a container golem working in a golem-named worktree could
# regress to keying the feed on agentNN and nothing would catch it (#797).
test_golem_named_worktree_outranks_agent_id() {
    local wt got
    wt=$(setup_golem_worktree 42)
    got=$(run_hook_env "$HOOK_REPO" "$wt" "aaaaaaaa11112222" AGENT_ID=agent07)
    assert_equals "golem-42" "$got" "golem-named worktree root outranks AGENT_ID"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$(/usr/bin/dirname "$wt")")"
}
run_test test_golem_named_worktree_outranks_agent_id "golem-named worktree root outranks AGENT_ID (#797)"

# The `?*` guard on $AGENT_ID matches any NON-EMPTY string — whitespace
# included — so a whitespace-only value takes the AGENT_ID arm and is keyed
# verbatim rather than falling through to primary. That is standard glob
# semantics, and it is the behavior both hooks agree on: claude-host-event.sh
# keys the same value as `<project>-   `. Pinned here so the guard's boundary is
# explicit — the empty case (test_empty_agent_id_falls_through) is the only side
# that falls through — and so the jq path is shown to escape the value correctly
# (#797).
test_whitespace_agent_id_is_kept() {
    local main got
    main=$(setup_plain_repo)
    got=$(run_hook_env "$HOOK_REPO" "$main" "aaaaaaaa11112222" AGENT_ID='   ')
    assert_equals "   " "$got" "a whitespace-only AGENT_ID matches ?* and is keyed verbatim, not fallen through"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$main")"
}
run_test test_whitespace_agent_id_is_kept "whitespace-only AGENT_ID matches the ?* guard (#797)"

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
# Cross-hook label agreement (gap 4 / #756, extended for #766). #750's "both
# hooks agree" AC was only satisfied by matching hardcoded literals across the
# two test files — nothing drove BOTH hooks with identical input and diffed the
# resulting label. This does exactly that: one plain repo, one identical env and
# payload session_id fed to both hooks, then asserts the host-event POST key is
# the golem-notify feed id with the `<project>-` prefix.
#
# golem-notify emits `.golem` = `<role>-<short>` (no project prefix — the feed is
# already per-repo); claude-host-event POSTs `.session_id` = `<project>-<role>-<short>`
# (the host bridge keys globally, so it needs the project). Agreement therefore
# means: host_event_session_id == "<project>-" + golem_notify_golem.
#
# PARAMETERIZED over the identity rung under test, because the orchestrator-only
# original is precisely why the AGENT_ID divergence (#766) went uncaught: the
# marker rung is shared code, so driving it proved nothing about the rungs above
# it. A future identity rung is covered by adding one `run_agreement_case` call,
# not a third near-duplicate function.
# ===========================================================================
HOOK_HOST_EVENT="$CONTAINERS_DIR/lib/features/templates/claude/hooks/claude-host-event.sh"

# Drive both hooks with identical input and assert they agree.
# Args: <expected_feed_id> <session_id> [KEY=VAL ...]
run_agreement_case() {
    local expect_golem="$1" session_id="$2"
    shift 2
    local main proj stubdir capture golem_id host_sid

    main=$(setup_plain_repo)
    proj=$(/usr/bin/basename "$main")

    # 1. golem-notify -> read `.golem` from its feed. Every identity var is
    #    scrubbed first so ONLY the caller's pairs classify the session.
    golem_id=$(
        cd "$main"
        env -u GOLEM_ID -u AGENT_ID -u CLAUDE_SESSION_ROLE "$@" "$HOOK_REPO" \
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
    host_sid=$(
        cd "$main"
        # Clear BASH_ENV so /etc/bash_env can't rebuild PATH and re-shadow the
        # stub curl with the real one (see #618). PROJECT_NAME is scrubbed too so
        # `project` comes from the repo basename, matching `$proj` below.
        env -u GOLEM_ID -u AGENT_ID -u CLAUDE_SESSION_ROLE -u PROJECT_NAME -u BASH_ENV \
            "$@" \
            CAPTURE="$capture" PATH="$stubdir:$PATH" \
            NOTCHBAR_AGENTS_HOST=127.0.0.1 NOTCHBAR_AGENTS_PORT=59990 \
            "$HOOK_HOST_EVENT" Ended \
            <<<"{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"$session_id\"}" >/dev/null 2>&1
        /usr/bin/jq -r '.session_id' "$capture" 2>/dev/null
    )

    # Sanity: both hooks resolved the EXPECTED non-empty label for this input.
    # Without these, a shared regression to `primary` on both sides would still
    # satisfy the agreement assertion below.
    assert_equals "$expect_golem" "$golem_id" "golem-notify feed id for the shared input"
    assert_equals "${proj}-${expect_golem}" "$host_sid" "host-event POST key for the shared input"
    # The core agreement assertion: host-event key == "<project>-" + feed id.
    assert_equals "${proj}-${golem_id}" "$host_sid" "both hooks classify identical input to the same label"

    /usr/bin/rm -rf "$stubdir" "$(/usr/bin/dirname "$main")"
}

# Rung 4 — the orchestrator marker. The original #756 case: a shared code path
# in both hooks, which is why it could not have caught #766.
test_cross_hook_agreement_orchestrator() {
    run_agreement_case "orchestrator-aaaaaaaa" "aaaaaaaa11112222" \
        CLAUDE_SESSION_ROLE=orchestrator
}
run_test test_cross_hook_agreement_orchestrator "both hooks agree for orchestrator-marked input (#756)"

# Rung 3 — $AGENT_ID. THE regression test for #766: before the AGENT_ID arm
# landed, golem-notify keyed this session `primary-aaaaaaaa` while host-event
# keyed it `<project>-agent07`, so this case fails loudly on the divergence.
# Note the bare `agent07` on both sides — no `-<short>` suffix, since AGENT_ID is
# already a stable unique id (see the rung-3 comment in the hook).
test_cross_hook_agreement_agent_id() {
    run_agreement_case "agent07" "aaaaaaaa11112222" AGENT_ID=agent07
}
run_test test_cross_hook_agreement_agent_id "both hooks agree for AGENT_ID-only input (#766)"

# Rung 1 — $GOLEM_ID. The deterministic launch-stamped id, likewise bare.
test_cross_hook_agreement_golem_id() {
    run_agreement_case "golem-999" "aaaaaaaa11112222" GOLEM_ID=golem-999
}
run_test test_cross_hook_agreement_golem_id "both hooks agree for GOLEM_ID input (#766)"

# ===========================================================================
# Generate report
# ===========================================================================
generate_report
