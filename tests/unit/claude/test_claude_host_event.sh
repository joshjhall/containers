#!/usr/bin/env bash
# Tests for claude-host-event.sh session identity + project resolution (#746).
#
# The host-event forwarder pushes each Claude Code hook event to a host monitor
# bridge that keys every row SOLELY on `session_id`. Three defects for non-golem
# sessions are covered here:
#   1. A primary/interactive session (human in the main checkout, or an
#      orchestrator) used to fall through to the `golem-?` placeholder. It now
#      resolves to a `primary` identity keyed `<project>-primary-<short>`.
#   2. Concurrent primary sessions (multiple shell tabs) used to collapse onto
#      one `<project>-golem-?` key and clobber each other. They are now
#      differentiated by the Claude-native session_id (first 8 chars).
#   3. A worktree golem's project used to resolve to `.worktrees` (the parent of
#      the worktree dir) instead of the real root checkout name. It now resolves
#      via the git COMMON dir's parent, so it reports the root project.
#
# The hook POSTs its payload via `curl --data-raw <json>`; these tests stub
# `curl` on PATH to capture that payload instead of hitting a real bridge. A
# real main checkout + linked worktree is built so `git rev-parse
# --git-common-dir` / `--show-toplevel` resolve exactly as for a live golem.

set -euo pipefail

# These tests create throwaway git repos + worktrees under /tmp. Inherited git
# env (GIT_DIR etc. from a pre-push hook) is cleared centrally at framework.sh
# module scope when sourced below, so no per-test unset is needed. See #599.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../framework.sh"
init_test_framework

# The forwarder ships as a build-bound template; exercise that copy.
HOOK="$CONTAINERS_DIR/lib/features/templates/claude/hooks/claude-host-event.sh"

test_suite "claude-host-event.sh identity + project (#746)"

# ---------------------------------------------------------------------------
# Build a main checkout with a linked `.worktrees/issue-<N>` worktree, mirroring
# the real golem layout. Echoes the worktree path on stdout. The main checkout's
# basename is randomized (mktemp) — the tests assert the RESOLVED project name
# equals that root basename, never a hardcoded string, so they hold regardless
# of where the suite runs.
# ---------------------------------------------------------------------------
setup_worktree() {
    local n="$1"
    local main
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

# A `curl` stub that captures the --data-raw payload to $CAPTURE and exits 0
# (so the hook's fire-and-forget POST "succeeds"). Placed first on PATH.
make_curl_stub() {
    local stubdir="$1" capture="$2"
    /usr/bin/cat >"$stubdir/curl" <<STUB
#!/usr/bin/env bash
# Test stub: record the --data-raw argument, ignore everything else.
prev=""
for a in "\$@"; do
    if [ "\$prev" = "--data-raw" ]; then
        /usr/bin/printf '%s' "\$a" >"$capture"
        break
    fi
    prev="\$a"
done
exit 0
STUB
    /usr/bin/chmod +x "$stubdir/curl"
}

# Run the hook with a chosen cwd, environment, STATE, and stdin payload, then
# echo the captured POST body (JSON). Args:
#   <cwd> <state> <hook_json> [env assignments...]
# Environment control vars (GOLEM_ID/AGENT_ID/PROJECT_NAME) are passed as extra
# KEY=VAL args and forwarded verbatim; unset any you want absent with `-u` via
# the caller using env is not possible here, so callers pass explicit values and
# rely on a clean base (we `env -i`-style scrub the three identity vars).
run_hook_capture() {
    local cwd="$1" state="$2" hook_json="$3"
    shift 3
    local stubdir capture
    stubdir=$(/usr/bin/mktemp -d)
    capture="$stubdir/body.json"
    make_curl_stub "$stubdir" "$capture"
    (
        cd "$cwd"
        # Scrub the three identity vars, then apply caller-supplied ones. Prepend
        # the stub dir so our curl wins; keep the real PATH for git/python3/etc.
        # BASH_ENV must be cleared: /etc/bash_env rebuilds PATH on every
        # non-interactive bash (the hook's shebang), which would re-shadow the
        # stub `curl` with the real one. See #618 (bash-env-breaks-path-stubs).
        env -u GOLEM_ID -u AGENT_ID -u PROJECT_NAME -u BASH_ENV \
            PATH="$stubdir:$PATH" \
            NOTCHBAR_AGENTS_HOST=127.0.0.1 NOTCHBAR_AGENTS_PORT=59990 \
            "$@" \
            "$HOOK" "$state" <<<"$hook_json" >/dev/null 2>&1
    )
    /usr/bin/cat "$capture" 2>/dev/null
    /usr/bin/rm -rf "$stubdir"
}

# Convenience: extract a field from the captured JSON body.
body_field() { /usr/bin/printf '%s' "$1" | /usr/bin/jq -r "$2" 2>/dev/null; }

# Seed a per-issue pipeline state file with a given phase into a worktree's
# `.claude/memory/tmp/`, so the hook's phase→activity mapping has a file to
# read. Args: <worktree> <issue-N> <phase-or-raw-json>. When the third arg looks
# like JSON (starts with `{`) it is written verbatim (used to inject malformed
# JSON); otherwise it is treated as a phase value in a minimal valid state file.
write_state() {
    local wt="$1" n="$2" phase="$3"
    local tmp="$wt/.claude/memory/tmp"
    /usr/bin/mkdir -p "$tmp"
    case "$phase" in
        '{'*) /usr/bin/printf '%s' "$phase" >"$tmp/next-issue-${n}.json" ;;
        *)
            /usr/bin/printf \
                '{"version":2,"issue":%s,"title":"t","phase":"%s","started":"2026-07-19","platform":"github"}' \
                "$n" "$phase" >"$tmp/next-issue-${n}.json"
            ;;
    esac
}

# ===========================================================================
# Worktree golem: project resolves to the ROOT checkout, not `.worktrees`
# (#746 defect 3), and the golem id is issue-N -> golem-N.
# ===========================================================================
test_worktree_project_is_root_not_dotworktrees() {
    local wt root body sid
    wt=$(setup_worktree 720)
    # <main>/.worktrees/issue-720 -> root basename is <main>
    root=$(/usr/bin/basename "$(/usr/bin/dirname "$(/usr/bin/dirname "$wt")")")
    body=$(run_hook_capture "$wt" "Ended" '{"hook_event_name":"SessionEnd","session_id":"deadbeefcafe0000"}')
    sid=$(body_field "$body" '.session_id')
    assert_equals "${root}-golem-720" "$sid" "worktree golem keys on root project, not .worktrees"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$(/usr/bin/dirname "$wt")")"
}
run_test test_worktree_project_is_root_not_dotworktrees "worktree golem project = root checkout, not .worktrees (#746)"

# ===========================================================================
# Project resolution from a SUBDIRECTORY of a plain/main checkout. `git
# rev-parse --git-common-dir` returns a RELATIVE path (`../../.git`) there, so a
# string-only dirname/basename would resolve the project to the literal `..`.
# The hook must `cd`-canonicalize to recover the real root basename (#746
# regression — caught by the pre-PR review). A worktree's common-dir is absolute
# at any depth, so this case is specific to the non-worktree checkout.
# ===========================================================================
test_primary_project_from_subdirectory() {
    local main proj sub body sid
    main=$(/usr/bin/mktemp -d)/realproj
    /usr/bin/mkdir -p "$main/lib/features"
    (
        cd "$main"
        /usr/bin/git init -q .
        /usr/bin/git config user.email t@t.t
        /usr/bin/git config user.name t
        /usr/bin/git commit -q --allow-empty -m init
    )
    proj=$(/usr/bin/basename "$main") # "realproj"
    sub="$main/lib/features"          # two levels below the root
    body=$(run_hook_capture "$sub" "Ended" '{"hook_event_name":"SessionEnd","session_id":"abcdef1234567890"}')
    sid=$(body_field "$body" '.session_id')
    assert_equals "${proj}-primary-abcdef12" "$sid" "project resolves to root basename from a subdir, not '..'"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$main")"
}
run_test test_primary_project_from_subdirectory "project resolves via cd-canonicalize from a subdir, not '..' (#746)"

# ===========================================================================
# A malformed GOLEM_ID (not golem-*) is ignored; falls back to worktree-root
# resolution (mirrors test_golem_notify.sh's test_bad_golem_id_falls_back).
# ===========================================================================
test_bad_golem_id_falls_back() {
    local wt root body sid
    wt=$(setup_worktree 723)
    root=$(/usr/bin/basename "$(/usr/bin/dirname "$(/usr/bin/dirname "$wt")")")
    body=$(run_hook_capture "$wt" "Ended" '{"hook_event_name":"SessionEnd","session_id":"cafebabe"}' GOLEM_ID=garbage)
    sid=$(body_field "$body" '.session_id')
    assert_equals "${root}-golem-723" "$sid" "malformed GOLEM_ID ignored, falls back to worktree root"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$(/usr/bin/dirname "$wt")")"
}
run_test test_bad_golem_id_falls_back "malformed GOLEM_ID falls back to worktree root (#746)"

# ===========================================================================
# Primary session (plain repo, not issue-*/golem-*, no GOLEM_ID/AGENT_ID) is
# keyed `<project>-primary-<short>` where short is the payload session_id[:8].
# ===========================================================================
test_primary_session_keyed_by_native_session_id() {
    local main proj body sid title
    main=$(/usr/bin/mktemp -d)/myproj
    /usr/bin/mkdir -p "$main"
    (
        cd "$main"
        /usr/bin/git init -q .
        /usr/bin/git config user.email t@t.t
        /usr/bin/git config user.name t
        /usr/bin/git commit -q --allow-empty -m init
    )
    proj=$(/usr/bin/basename "$main") # "myproj"
    body=$(run_hook_capture "$main" "Ended" '{"hook_event_name":"SessionEnd","session_id":"abcdef1234567890"}')
    sid=$(body_field "$body" '.session_id')
    title=$(body_field "$body" '.title')
    assert_equals "${proj}-primary-abcdef12" "$sid" "primary session keyed by project + native session_id prefix"
    assert_equals "${proj} · primary" "$title" "primary session title is legible, not golem-?"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$main")"
}
run_test test_primary_session_keyed_by_native_session_id "primary session keyed <project>-primary-<short> (#746)"

# ===========================================================================
# Anti-collision: two concurrent primary sessions (different native session_ids)
# in the SAME repo produce two DISTINCT host keys, not one shared `-primary`.
# ===========================================================================
test_concurrent_primary_sessions_distinct_keys() {
    local main body_a body_b sid_a sid_b
    main=$(/usr/bin/mktemp -d)/proj2
    /usr/bin/mkdir -p "$main"
    (
        cd "$main"
        /usr/bin/git init -q .
        /usr/bin/git config user.email t@t.t
        /usr/bin/git config user.name t
        /usr/bin/git commit -q --allow-empty -m init
    )
    # Use STATE=Ended so the hook's POST is synchronous (non-terminal states
    # background the curl with `&`, racing the capture read). The identity logic
    # is STATE-independent — STATE only selects sync vs async delivery.
    body_a=$(run_hook_capture "$main" "Ended" '{"hook_event_name":"UserPromptSubmit","session_id":"aaaaaaaa11112222","prompt":"tab one"}')
    body_b=$(run_hook_capture "$main" "Ended" '{"hook_event_name":"UserPromptSubmit","session_id":"bbbbbbbb33334444","prompt":"tab two"}')
    sid_a=$(body_field "$body_a" '.session_id')
    sid_b=$(body_field "$body_b" '.session_id')
    assert_equals "proj2-primary-aaaaaaaa" "$sid_a" "tab one gets its own host key"
    assert_equals "proj2-primary-bbbbbbbb" "$sid_b" "tab two gets its own host key"
    if [ "$sid_a" = "$sid_b" ]; then
        fail_test "concurrent primary sessions must not collide on one host key"
    else
        pass_test
    fi
    /usr/bin/rm -rf "$(/usr/bin/dirname "$main")"
}
run_test test_concurrent_primary_sessions_distinct_keys "concurrent primary tabs get distinct host keys (#746)"

# ===========================================================================
# Orchestrator marker (#750). A session marked CLAUDE_SESSION_ROLE=orchestrator
# — a non-golem session driving a fleet via /orchestrate — is a LABELED VARIANT
# of `primary`: keyed `<project>-orchestrator-<short>` and titled
# `<project> · orchestrator`, per-tab differentiated by the native session_id
# exactly like primary, so the host monitor shows who is coordinating the fleet
# (AC1) instead of an indistinct `primary` row.
# ===========================================================================
test_orchestrator_keyed_and_titled() {
    local main proj body sid title
    main=$(/usr/bin/mktemp -d)/orchproj
    /usr/bin/mkdir -p "$main"
    (
        cd "$main"
        /usr/bin/git init -q .
        /usr/bin/git config user.email t@t.t
        /usr/bin/git config user.name t
        /usr/bin/git commit -q --allow-empty -m init
    )
    proj=$(/usr/bin/basename "$main")
    body=$(run_hook_capture "$main" "Ended" '{"hook_event_name":"SessionEnd","session_id":"abcdef1234567890"}' CLAUDE_SESSION_ROLE=orchestrator)
    sid=$(body_field "$body" '.session_id')
    title=$(body_field "$body" '.title')
    assert_equals "${proj}-orchestrator-abcdef12" "$sid" "orchestrator keyed by project + native session_id prefix"
    assert_equals "${proj} · orchestrator" "$title" "orchestrator session title reads 'orchestrator', not 'primary'"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$main")"
}
run_test test_orchestrator_keyed_and_titled "orchestrator marker keyed <project>-orchestrator-<short> (#750)"

# Two concurrent orchestrator tabs (different native session_ids) get DISTINCT
# host keys — the same anti-collision guarantee as primary.
test_concurrent_orchestrator_sessions_distinct_keys() {
    local main body_a body_b sid_a sid_b
    main=$(/usr/bin/mktemp -d)/orch2
    /usr/bin/mkdir -p "$main"
    (
        cd "$main"
        /usr/bin/git init -q .
        /usr/bin/git config user.email t@t.t
        /usr/bin/git config user.name t
        /usr/bin/git commit -q --allow-empty -m init
    )
    body_a=$(run_hook_capture "$main" "Ended" '{"hook_event_name":"UserPromptSubmit","session_id":"aaaaaaaa11112222","prompt":"orch one"}' CLAUDE_SESSION_ROLE=orchestrator)
    body_b=$(run_hook_capture "$main" "Ended" '{"hook_event_name":"UserPromptSubmit","session_id":"bbbbbbbb33334444","prompt":"orch two"}' CLAUDE_SESSION_ROLE=orchestrator)
    sid_a=$(body_field "$body_a" '.session_id')
    sid_b=$(body_field "$body_b" '.session_id')
    assert_equals "orch2-orchestrator-aaaaaaaa" "$sid_a" "orchestrator tab one gets its own host key"
    assert_equals "orch2-orchestrator-bbbbbbbb" "$sid_b" "orchestrator tab two gets its own host key"
    if [ "$sid_a" = "$sid_b" ]; then
        fail_test "concurrent orchestrator sessions must not collide on one host key"
    else
        pass_test
    fi
    /usr/bin/rm -rf "$(/usr/bin/dirname "$main")"
}
run_test test_concurrent_orchestrator_sessions_distinct_keys "concurrent orchestrator tabs get distinct host keys (#750)"

# The marker acts ONLY on the primary fallback — a real golem is never
# reclassified. $GOLEM_ID and the orchestrator marker set together -> still the
# golem id (the golem arm outranks the marker).
test_golem_id_outranks_orchestrator_marker() {
    local main proj body sid
    main=$(/usr/bin/mktemp -d)/orch3
    /usr/bin/mkdir -p "$main"
    (
        cd "$main"
        /usr/bin/git init -q .
        /usr/bin/git config user.email t@t.t
        /usr/bin/git config user.name t
        /usr/bin/git commit -q --allow-empty -m init
    )
    proj=$(/usr/bin/basename "$main")
    body=$(run_hook_capture "$main" "Ended" '{"hook_event_name":"SessionEnd","session_id":"ffff0000ffff0000"}' GOLEM_ID=golem-999 CLAUDE_SESSION_ROLE=orchestrator)
    sid=$(body_field "$body" '.session_id')
    assert_equals "${proj}-golem-999" "$sid" "GOLEM_ID outranks the orchestrator marker (marker only acts on the primary fallback)"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$main")"
}
run_test test_golem_id_outranks_orchestrator_marker "golem id outranks orchestrator marker (#750)"

# An orchestrator is not in the per-issue pipeline, so a stray next-issue-*.json
# in its checkout must NOT paint a phase verb — the activity line stays its own
# prompt (mirrors the primary guard in test_primary_session_unaffected_by_state_file).
test_orchestrator_session_no_phase_verb() {
    local main proj body title
    main=$(/usr/bin/mktemp -d)/orch4
    /usr/bin/mkdir -p "$main"
    (
        cd "$main"
        /usr/bin/git init -q .
        /usr/bin/git config user.email t@t.t
        /usr/bin/git config user.name t
        /usr/bin/git commit -q --allow-empty -m init
    )
    proj=$(/usr/bin/basename "$main")
    write_state "$main" 300 plan
    body=$(run_hook_capture "$main" "Ended" '{"hook_event_name":"UserPromptSubmit","session_id":"cccccccc1111","prompt":"dispatching golems"}' CLAUDE_SESSION_ROLE=orchestrator)
    title=$(body_field "$body" '.title')
    assert_equals "${proj} · orchestrator · dispatching golems" "$title" "orchestrator keeps its prompt, no phase verb from a stray state file"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$main")"
}
run_test test_orchestrator_session_no_phase_verb "orchestrator session unaffected by a stray state file (#750)"

# An unset marker (and a non-'orchestrator' value) falls through to primary —
# the marker is fail-safe, never accidentally promoting a human session.
test_unmarked_or_unknown_role_is_primary() {
    local main proj body sid
    main=$(/usr/bin/mktemp -d)/orch5
    /usr/bin/mkdir -p "$main"
    (
        cd "$main"
        /usr/bin/git init -q .
        /usr/bin/git config user.email t@t.t
        /usr/bin/git config user.name t
        /usr/bin/git commit -q --allow-empty -m init
    )
    proj=$(/usr/bin/basename "$main")
    # A non-orchestrator role value must NOT classify as orchestrator.
    body=$(run_hook_capture "$main" "Ended" '{"hook_event_name":"SessionEnd","session_id":"abcdef1234567890"}' CLAUDE_SESSION_ROLE=something-else)
    sid=$(body_field "$body" '.session_id')
    assert_equals "${proj}-primary-abcdef12" "$sid" "an unknown CLAUDE_SESSION_ROLE falls through to primary (fail-safe)"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$main")"
}
run_test test_unmarked_or_unknown_role_is_primary "unknown CLAUDE_SESSION_ROLE falls through to primary (#750)"

# ===========================================================================
# $GOLEM_ID takes precedence over path resolution — a stamped golem is keyed by
# its id even from a plain (non-worktree) cwd.
# ===========================================================================
test_golem_id_env_precedence() {
    local main proj body sid
    main=$(/usr/bin/mktemp -d)/proj3
    /usr/bin/mkdir -p "$main"
    (
        cd "$main"
        /usr/bin/git init -q .
        /usr/bin/git config user.email t@t.t
        /usr/bin/git config user.name t
        /usr/bin/git commit -q --allow-empty -m init
    )
    proj=$(/usr/bin/basename "$main")
    body=$(run_hook_capture "$main" "Ended" '{"hook_event_name":"SessionEnd","session_id":"ffff0000ffff0000"}' GOLEM_ID=golem-999)
    sid=$(body_field "$body" '.session_id')
    assert_equals "${proj}-golem-999" "$sid" "GOLEM_ID env is authoritative over path/primary"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$main")"
}
run_test test_golem_id_env_precedence "GOLEM_ID env takes precedence over primary fallback (#746)"

# ===========================================================================
# $AGENT_ID (container golems) resolves before the primary fallback.
# ===========================================================================
test_agent_id_before_primary() {
    local main proj body sid
    main=$(/usr/bin/mktemp -d)/proj4
    /usr/bin/mkdir -p "$main"
    (
        cd "$main"
        /usr/bin/git init -q .
        /usr/bin/git config user.email t@t.t
        /usr/bin/git config user.name t
        /usr/bin/git commit -q --allow-empty -m init
    )
    proj=$(/usr/bin/basename "$main")
    body=$(run_hook_capture "$main" "Ended" '{"hook_event_name":"SessionEnd","session_id":"1111222233334444"}' AGENT_ID=agent07)
    sid=$(body_field "$body" '.session_id')
    assert_equals "${proj}-agent07" "$sid" "AGENT_ID resolves before primary fallback"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$main")"
}
run_test test_agent_id_before_primary "AGENT_ID (container golem) resolves before primary (#746)"

# ===========================================================================
# PROJECT_NAME env overrides path-derived project (container golems stamp it).
# ===========================================================================
test_project_name_env_override() {
    local wt body sid
    wt=$(setup_worktree 721)
    body=$(run_hook_capture "$wt" "Ended" '{"hook_event_name":"SessionEnd","session_id":"5555666677778888"}' PROJECT_NAME=stamped)
    sid=$(body_field "$body" '.session_id')
    assert_equals "stamped-golem-721" "$sid" "explicit PROJECT_NAME wins over git-derived project"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$(/usr/bin/dirname "$wt")")"
}
run_test test_project_name_env_override "PROJECT_NAME env overrides derived project (#746)"

# ===========================================================================
# Primary session with NO native session_id in the payload falls back to the
# bare `<project>-primary` key (still valid, just non-differentiated).
# ===========================================================================
test_primary_without_session_id_bare_key() {
    local main proj body sid
    main=$(/usr/bin/mktemp -d)/proj5
    /usr/bin/mkdir -p "$main"
    (
        cd "$main"
        /usr/bin/git init -q .
        /usr/bin/git config user.email t@t.t
        /usr/bin/git config user.name t
        /usr/bin/git commit -q --allow-empty -m init
    )
    proj=$(/usr/bin/basename "$main")
    body=$(run_hook_capture "$main" "Ended" '{"hook_event_name":"SessionEnd"}')
    sid=$(body_field "$body" '.session_id')
    assert_equals "${proj}-primary" "$sid" "primary with no native session_id uses the bare key"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$main")"
}
run_test test_primary_without_session_id_bare_key "primary with no native session_id -> bare <project>-primary (#746)"

# ===========================================================================
# python-absent minimal fallback: still emits a valid, primary-keyed payload.
# Reaching the else-branch requires python3 ABSENT from PATH — build a PATH with
# only the commands the hook needs (bash, git, curl-stub, coreutils), no python3.
# ===========================================================================
test_python_absent_fallback_primary_keyed() {
    local main proj stubdir capture body sid
    main=$(/usr/bin/mktemp -d)/proj6
    /usr/bin/mkdir -p "$main"
    (
        cd "$main"
        /usr/bin/git init -q .
        /usr/bin/git config user.email t@t.t
        /usr/bin/git config user.name t
        /usr/bin/git commit -q --allow-empty -m init
    )
    proj=$(/usr/bin/basename "$main")

    stubdir=$(/usr/bin/mktemp -d)
    capture="$stubdir/body.json"
    make_curl_stub "$stubdir" "$capture"
    # Symlink only the non-python commands the hook resolves via PATH.
    /usr/bin/ln -s "$(command -v bash)" "$stubdir/bash"
    /usr/bin/ln -s "$(command -v git)" "$stubdir/git"
    /usr/bin/ln -s "$(command -v cat)" "$stubdir/cat"
    /usr/bin/ln -s "$(command -v basename)" "$stubdir/basename"
    /usr/bin/ln -s "$(command -v dirname)" "$stubdir/dirname"
    /usr/bin/ln -s "$(command -v pwd)" "$stubdir/pwd" 2>/dev/null || true
    (
        cd "$main"
        /usr/bin/env -i PATH="$stubdir" \
            NOTCHBAR_AGENTS_HOST=127.0.0.1 NOTCHBAR_AGENTS_PORT=59990 \
            "$HOOK" Ended <<<'{"hook_event_name":"SessionEnd","session_id":"abcdef1234567890"}' >/dev/null 2>&1
    )
    body=$(/usr/bin/cat "$capture" 2>/dev/null)
    # Must be valid JSON and keyed to the primary session (bare key on this path,
    # since python is absent to parse the native session_id).
    sid=$(body_field "$body" '.session_id')
    assert_equals "${proj}-primary" "$sid" "python-absent fallback still emits a primary-keyed session_id"
    /usr/bin/rm -rf "$stubdir" "$(/usr/bin/dirname "$main")"
}
run_test test_python_absent_fallback_primary_keyed "python-absent minimal fallback is valid + primary-keyed (#746)"

# ===========================================================================
# Contract: the hook always exits 0, even when curl is entirely absent (the
# POST must never block or fail the session).
# ===========================================================================
test_hook_always_exits_zero() {
    local wt rc=0
    wt=$(setup_worktree 722)
    # Capture rc explicitly with `|| rc=$?` so the suite's `set -e` does not
    # abort here on a (hypothetical) non-zero hook exit — we WANT to assert on
    # the code, not crash. No curl on PATH at all; the hook must still exit 0.
    (
        cd "$wt"
        env -u GOLEM_ID PATH="/usr/bin:/bin" \
            NOTCHBAR_AGENTS_HOST=127.0.0.1 NOTCHBAR_AGENTS_PORT=59990 \
            "$HOOK" Working <<<'{"hook_event_name":"UserPromptSubmit","session_id":"x"}' >/dev/null 2>&1
    ) || rc=$?
    assert_equals "0" "$rc" "hook exits 0 even with curl absent (never blocks the session)"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$(/usr/bin/dirname "$wt")")"
}
run_test test_hook_always_exits_zero "hook always exits 0 (fire-and-forget contract) (#746)"

# ===========================================================================
# Phase → activity mapping (#751). A golem in the /next-issue -> /ship-issue
# pipeline persists a `phase` to next-issue-{N}.json; the hook surfaces it as the
# activity portion of `title` ("<project> · golem-N · Planning") instead of the
# launch-prompt text (which for a golem just re-states the issue number).
# ===========================================================================
test_golem_phase_maps_to_activity_verb() {
    local wt root body title
    wt=$(setup_worktree 730)
    root=$(/usr/bin/basename "$(/usr/bin/dirname "$(/usr/bin/dirname "$wt")")")
    write_state "$wt" 730 plan
    # A UserPromptSubmit carrying the launch prompt: the phase verb must WIN over
    # the prompt-derived text, proving the phase override is authoritative.
    # STATE=Ended for synchronous POST (Working backgrounds the curl and races
    # the capture read; see the #746 anti-collision test). The payload's
    # UserPromptSubmit is what drives the title logic, independent of STATE.
    body=$(run_hook_capture "$wt" "Ended" '{"hook_event_name":"UserPromptSubmit","session_id":"aa","prompt":"/workflow:next-issue 730 --level 3"}')
    title=$(body_field "$body" '.title')
    assert_equals "${root} · golem-730 · Planning" "$title" "phase=plan surfaces as 'Planning', overriding the launch prompt"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$(/usr/bin/dirname "$wt")")"
}
run_test test_golem_phase_maps_to_activity_verb "golem phase=plan -> activity 'Planning' (#751)"

# Every phase value maps to its documented verb, on a non-UserPromptSubmit event
# (proving the activity line is a live readout, not tied to prompt submission).
test_all_phase_verbs() {
    local wt root body title p verb
    wt=$(setup_worktree 731)
    root=$(/usr/bin/basename "$(/usr/bin/dirname "$(/usr/bin/dirname "$wt")")")
    for pair in "select:Selecting" "plan:Planning" "implement:Building" "ship:Shipping"; do
        p="${pair%%:*}"
        verb="${pair##*:}"
        write_state "$wt" 731 "$p"
        body=$(run_hook_capture "$wt" "Ended" '{"hook_event_name":"SessionEnd","session_id":"bb"}')
        title=$(body_field "$body" '.title')
        assert_equals "${root} · golem-731 · ${verb}" "$title" "phase=${p} -> '${verb}' on a non-prompt event"
    done
    /usr/bin/rm -rf "$(/usr/bin/dirname "$(/usr/bin/dirname "$wt")")"
}
run_test test_all_phase_verbs "all pipeline phases map to their activity verbs (#751)"

# No state file: a golem's UserPromptSubmit still falls back to the prompt-derived
# title (the pre-#751 behavior), so the activity line is never worse than before.
test_no_state_file_falls_back_to_prompt() {
    local wt root body title
    wt=$(setup_worktree 732)
    root=$(/usr/bin/basename "$(/usr/bin/dirname "$(/usr/bin/dirname "$wt")")")
    body=$(run_hook_capture "$wt" "Ended" '{"hook_event_name":"UserPromptSubmit","session_id":"cc","prompt":"do a thing"}')
    title=$(body_field "$body" '.title')
    assert_equals "${root} · golem-732 · do a thing" "$title" "no state file -> prompt-derived title (unchanged fallback)"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$(/usr/bin/dirname "$wt")")"
}
run_test test_no_state_file_falls_back_to_prompt "no state file falls back to prompt-derived title (#751)"

# Malformed JSON in the state file must not crash the hook or emit a verb — it
# degrades to the bare label (no prompt here to fall back to).
test_malformed_state_file_graceful() {
    local wt root body title
    wt=$(setup_worktree 733)
    root=$(/usr/bin/basename "$(/usr/bin/dirname "$(/usr/bin/dirname "$wt")")")
    write_state "$wt" 733 '{ this is not json'
    body=$(run_hook_capture "$wt" "Ended" '{"hook_event_name":"SessionEnd","session_id":"dd"}')
    title=$(body_field "$body" '.title')
    assert_equals "${root} · golem-733" "$title" "malformed state JSON -> bare label, no verb, no crash"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$(/usr/bin/dirname "$wt")")"
}
run_test test_malformed_state_file_graceful "malformed state file degrades gracefully (#751)"

# An unknown phase value (schema drift / future phase) is not in the verb map, so
# it falls back rather than surfacing a raw phase string.
test_unknown_phase_falls_back() {
    local wt root body title
    wt=$(setup_worktree 734)
    root=$(/usr/bin/basename "$(/usr/bin/dirname "$(/usr/bin/dirname "$wt")")")
    write_state "$wt" 734 weird
    body=$(run_hook_capture "$wt" "Ended" '{"hook_event_name":"UserPromptSubmit","session_id":"ee","prompt":"fallback prompt"}')
    title=$(body_field "$body" '.title')
    assert_equals "${root} · golem-734 · fallback prompt" "$title" "unknown phase -> prompt fallback, not the raw phase"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$(/usr/bin/dirname "$wt")")"
}
run_test test_unknown_phase_falls_back "unknown phase value falls back (verb-map miss) (#751)"

# Container golem (AGENT_ID, id has no issue number): the phase is resolved from
# the SOLE per-issue state file via the glob fallback.
test_agent_id_golem_phase_from_sole_state_file() {
    local main proj body title
    main=$(/usr/bin/mktemp -d)/agentproj
    /usr/bin/mkdir -p "$main"
    (
        cd "$main"
        /usr/bin/git init -q .
        /usr/bin/git config user.email t@t.t
        /usr/bin/git config user.name t
        /usr/bin/git commit -q --allow-empty -m init
    )
    proj=$(/usr/bin/basename "$main")
    write_state "$main" 555 implement
    body=$(run_hook_capture "$main" "Ended" '{"hook_event_name":"SessionEnd","session_id":"ff"}' AGENT_ID=agent07)
    title=$(body_field "$body" '.title')
    assert_equals "${proj} · agent07 · Building" "$title" "AGENT_ID golem resolves phase from the sole state file"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$main")"
}
run_test test_agent_id_golem_phase_from_sole_state_file "AGENT_ID golem phase via sole-state-file glob (#751)"

# The singleton next-issue-queue.json is NOT a per-issue state file: with only it
# present (no next-issue-{N}.json), the glob fallback must find nothing.
test_queue_file_excluded_from_glob() {
    local main proj tmp body title
    main=$(/usr/bin/mktemp -d)/queueproj
    /usr/bin/mkdir -p "$main"
    (
        cd "$main"
        /usr/bin/git init -q .
        /usr/bin/git config user.email t@t.t
        /usr/bin/git config user.name t
        /usr/bin/git commit -q --allow-empty -m init
    )
    proj=$(/usr/bin/basename "$main")
    tmp="$main/.claude/memory/tmp"
    /usr/bin/mkdir -p "$tmp"
    /usr/bin/printf '{"target":9,"remaining":[9]}' >"$tmp/next-issue-queue.json"
    body=$(run_hook_capture "$main" "Ended" '{"hook_event_name":"UserPromptSubmit","session_id":"gg","prompt":"q prompt"}' AGENT_ID=agent08)
    title=$(body_field "$body" '.title')
    assert_equals "${proj} · agent08 · q prompt" "$title" "queue file is excluded; falls back to prompt"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$main")"
}
run_test test_queue_file_excluded_from_glob "next-issue-queue.json excluded from per-issue glob (#751)"

# A primary/human session must never grow a phase verb even if a stray state file
# exists in its checkout — the activity line stays the human's own prompt.
test_primary_session_unaffected_by_state_file() {
    local main proj body title
    main=$(/usr/bin/mktemp -d)/humanproj
    /usr/bin/mkdir -p "$main"
    (
        cd "$main"
        /usr/bin/git init -q .
        /usr/bin/git config user.email t@t.t
        /usr/bin/git config user.name t
        /usr/bin/git commit -q --allow-empty -m init
    )
    proj=$(/usr/bin/basename "$main")
    write_state "$main" 200 plan
    body=$(run_hook_capture "$main" "Ended" '{"hook_event_name":"UserPromptSubmit","session_id":"hhhhhhhh1111","prompt":"human task"}')
    title=$(body_field "$body" '.title')
    assert_equals "${proj} · primary · human task" "$title" "primary session keeps its prompt, no phase verb"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$main")"
}
run_test test_primary_session_unaffected_by_state_file "primary session unaffected by a stray state file (#751)"

# A golem-N whose OWN next-issue-N.json is absent must NOT borrow the phase of an
# unrelated issue's state file that happens to sit in the same worktree (a stale
# leftover). The glob fallback is gated to AGENT_ID golems (no issue number) —
# for a numbered golem a missing own-file yields no verb (prompt/bare fallback).
test_numbered_golem_ignores_unrelated_state_file() {
    local wt root body title
    wt=$(setup_worktree 740)
    root=$(/usr/bin/basename "$(/usr/bin/dirname "$(/usr/bin/dirname "$wt")")")
    # Seed a DIFFERENT issue's state file; golem-740's own file is absent.
    write_state "$wt" 999 implement
    body=$(run_hook_capture "$wt" "Ended" '{"hook_event_name":"UserPromptSubmit","session_id":"ii","prompt":"launch prompt"}')
    title=$(body_field "$body" '.title')
    assert_equals "${root} · golem-740 · launch prompt" "$title" "numbered golem does not borrow an unrelated issue's phase"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$(/usr/bin/dirname "$wt")")"
}
run_test test_numbered_golem_ignores_unrelated_state_file "numbered golem ignores unrelated state file (no false phase) (#751)"

# Ambiguous AGENT_ID case: 2+ per-issue state files -> the fallback gives up
# (can't tell which issue this golem is on) and falls back to the prompt.
test_agent_id_ambiguous_multiple_state_files() {
    local main proj body title
    main=$(/usr/bin/mktemp -d)/ambigproj
    /usr/bin/mkdir -p "$main"
    (
        cd "$main"
        /usr/bin/git init -q .
        /usr/bin/git config user.email t@t.t
        /usr/bin/git config user.name t
        /usr/bin/git commit -q --allow-empty -m init
    )
    proj=$(/usr/bin/basename "$main")
    write_state "$main" 501 plan
    write_state "$main" 502 ship
    body=$(run_hook_capture "$main" "Ended" '{"hook_event_name":"UserPromptSubmit","session_id":"jj","prompt":"agent prompt"}' AGENT_ID=agent09)
    title=$(body_field "$body" '.title')
    assert_equals "${proj} · agent09 · agent prompt" "$title" "ambiguous multi-file glob gives up, falls back to prompt"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$main")"
}
run_test test_agent_id_ambiguous_multiple_state_files "AGENT_ID ambiguous multi-file glob -> fallback (#751)"

# Valid JSON but no `phase` key (or a non-string phase) degrades like an unknown
# phase: no verb, bare label.
test_valid_json_missing_phase_key() {
    local wt root body title
    wt=$(setup_worktree 741)
    root=$(/usr/bin/basename "$(/usr/bin/dirname "$(/usr/bin/dirname "$wt")")")
    write_state "$wt" 741 '{"version":2,"issue":741}'
    body=$(run_hook_capture "$wt" "Ended" '{"hook_event_name":"SessionEnd","session_id":"kk"}')
    title=$(body_field "$body" '.title')
    assert_equals "${root} · golem-741" "$title" "valid JSON with no phase key -> bare label, no verb"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$(/usr/bin/dirname "$wt")")"
}
run_test test_valid_json_missing_phase_key "valid JSON missing 'phase' key degrades gracefully (#751)"

# Non-git directory: the `toplevel` shell resolution falls back to $(pwd); the
# hook must still exit 0 and emit a valid primary-keyed payload (no state file
# exists there, so no verb).
test_non_git_dir_pwd_fallback() {
    local dir body sid rc=0
    dir=$(/usr/bin/mktemp -d)/plain
    /usr/bin/mkdir -p "$dir"
    body=$(run_hook_capture "$dir" "Ended" '{"hook_event_name":"SessionEnd","session_id":"abcdef1234567890"}') || rc=$?
    sid=$(body_field "$body" '.session_id')
    # basename of the non-git dir becomes the project; primary session, bare-ish key.
    assert_equals "plain-primary-abcdef12" "$sid" "non-git dir: pwd-fallback still yields a valid primary key"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$dir")"
}
run_test test_non_git_dir_pwd_fallback "non-git dir pwd-fallback exits with valid payload (#751)"

# Contract still holds with a state file present: the hook exits 0.
test_hook_exits_zero_with_state_file() {
    local wt rc=0
    wt=$(setup_worktree 735)
    write_state "$wt" 735 ship
    (
        cd "$wt"
        env -u GOLEM_ID PATH="/usr/bin:/bin" \
            NOTCHBAR_AGENTS_HOST=127.0.0.1 NOTCHBAR_AGENTS_PORT=59990 \
            "$HOOK" Working <<<'{"hook_event_name":"UserPromptSubmit","session_id":"x"}' >/dev/null 2>&1
    ) || rc=$?
    assert_equals "0" "$rc" "hook exits 0 with a state file present (fire-and-forget)"
    /usr/bin/rm -rf "$(/usr/bin/dirname "$(/usr/bin/dirname "$wt")")"
}
run_test test_hook_exits_zero_with_state_file "hook exits 0 with a state file present (#751)"

# ===========================================================================
# Generate report
# ===========================================================================
generate_report
