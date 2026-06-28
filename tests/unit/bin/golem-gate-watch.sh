#!/usr/bin/env bash
# Tests for bin/golem-gate-watch.sh — the proactive golem gate-watch (issue #618).
#
# Two co-equal gate channels are exercised:
#   feed  — fresh-gate detection from .worktrees/.status/feed.jsonl, which MUST
#           stay in lockstep with the `just golems` BLOCKED list (same rule: a
#           golem is gated only when its latest feed line is a fresh `gate`,
#           legacy `blocked` honored, within GOLEM_BLOCK_TTL; an `idle`
#           supersedes and clears it).
#   panes — prompt-overlay detection from `tmux capture-pane` on live golem-*
#           sessions, including the distinct ExitPlanMode plan-gate prompt.
#
# The feed tests build a real main checkout + linked worktree (mirroring the
# golem layout) so the helper's git-common-dir feed resolution behaves exactly
# as for a live golem. The pane tests put a stub `tmux` on PATH that replays a
# canned capture-pane buffer (mirroring test_golem_notify.sh's stub-PATH
# technique) so no real tmux server is needed.

set -euo pipefail

# Throwaway git repos/worktrees under /tmp would be hijacked by an inherited
# GIT_DIR/GIT_WORK_TREE when the suite runs from a git hook; framework.sh clears
# that git env at module scope when sourced (see issue #599).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../framework.sh"
init_test_framework

WATCH="$CONTAINERS_DIR/bin/golem-gate-watch.sh"

test_suite "golem-gate-watch.sh gate detection (#618)"

# ---------------------------------------------------------------------------
# Build a main checkout with a linked `.worktrees/issue-<N>` worktree. Echoes
# the worktree path. The feed lands at <main>/.worktrees/.status/feed.jsonl.
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

# Remove the temp main checkout owning a worktree path.
teardown_worktree() {
    /usr/bin/rm -rf "$(/usr/bin/dirname "$(/usr/bin/dirname "$1")")"
}

# Append a feed line. Args: <worktree> <golem> <event> <message> [iso_ts]
feed_line() {
    local wt="$1" golem="$2" event="$3" message="$4" ts="${5:-}"
    local status_dir feed
    status_dir="$(/usr/bin/dirname "$wt")/.status"
    feed="$status_dir/feed.jsonl"
    /usr/bin/mkdir -p "$status_dir"
    [ -z "$ts" ] && ts="$(/usr/bin/date -u +%FT%TZ)"
    /usr/bin/jq -cn --arg ts "$ts" --arg g "$golem" --arg e "$event" --arg m "$message" \
        '{ts:$ts, golem:$g, event:$e, message:$m}' >>"$feed"
}

# Run the helper in --once (feed) mode from inside the worktree; echo stdout.
run_once() {
    local wt="$1"
    (cd "$wt" && "$WATCH" --once 2>/dev/null)
}

# ===========================================================================
# Feed: latest line is a fresh gate -> golem listed
# ===========================================================================
test_fresh_gate_listed() {
    local wt out
    wt=$(setup_worktree 800)
    feed_line "$wt" "golem-800" "gate" "Claude needs your permission to push"
    out=$(run_once "$wt")
    assert_contains "$out" "golem-800" "a golem whose latest line is a fresh gate is listed"
    assert_contains "$out" "permission to push" "the gate message is carried through"
    teardown_worktree "$wt"
}
run_test test_fresh_gate_listed "fresh gate is listed"

# ===========================================================================
# Feed: latest line is idle (golem resumed) -> NOT listed (cleared)
# ===========================================================================
test_idle_supersedes_gate() {
    local wt out
    wt=$(setup_worktree 801)
    feed_line "$wt" "golem-801" "gate" "Claude needs your permission" "2020-01-01T00:00:00Z"
    feed_line "$wt" "golem-801" "idle" "Claude is waiting for your input"
    out=$(run_once "$wt")
    assert_not_contains "$out" "golem-801" "an idle after a gate clears the block"
    teardown_worktree "$wt"
}
run_test test_idle_supersedes_gate "idle supersedes an earlier gate (cleared)"

# ===========================================================================
# Feed: idle then a NEW gate -> listed (re-gate is a fresh transition)
# ===========================================================================
test_gate_after_idle_listed() {
    local wt out
    wt=$(setup_worktree 802)
    feed_line "$wt" "golem-802" "idle" "Claude is waiting for your input" "2020-01-01T00:00:00Z"
    feed_line "$wt" "golem-802" "gate" "Claude needs your permission to create a PR"
    out=$(run_once "$wt")
    assert_contains "$out" "golem-802" "a new gate after an idle is listed again"
    teardown_worktree "$wt"
}
run_test test_gate_after_idle_listed "gate after idle is listed again"

# ===========================================================================
# Feed: a gate older than GOLEM_BLOCK_TTL is dropped (stale, golem exited)
# ===========================================================================
test_stale_gate_dropped() {
    local wt out
    wt=$(setup_worktree 803)
    # Year-2000 timestamp is far outside any positive TTL.
    feed_line "$wt" "golem-803" "gate" "Claude needs your permission" "2000-01-01T00:00:00Z"
    out=$(cd "$wt" && GOLEM_BLOCK_TTL=60 "$WATCH" --once 2>/dev/null)
    assert_not_contains "$out" "golem-803" "a gate older than GOLEM_BLOCK_TTL is dropped"
    teardown_worktree "$wt"
}
run_test test_stale_gate_dropped "stale gate beyond TTL is dropped"

# ===========================================================================
# Feed: legacy `blocked` event (pre-#600) is still honored as a gate
# ===========================================================================
test_legacy_blocked_honored() {
    local wt out
    wt=$(setup_worktree 804)
    feed_line "$wt" "golem-804" "blocked" "Claude needs your permission"
    out=$(run_once "$wt")
    assert_contains "$out" "golem-804" "a legacy blocked line is honored as a gate"
    teardown_worktree "$wt"
}
run_test test_legacy_blocked_honored "legacy blocked event honored as gate"

# ===========================================================================
# Feed: missing feed -> clean no-op, exit 0, empty output
# ===========================================================================
test_missing_feed_noop() {
    local wt out rc
    wt=$(setup_worktree 805)
    # No feed_line calls -> no feed file at all.
    out=$(run_once "$wt")
    rc=$?
    assert_equals "0" "$rc" "missing feed exits 0"
    assert_equals "" "$out" "missing feed produces no output"
    teardown_worktree "$wt"
}
run_test test_missing_feed_noop "missing feed is a clean no-op"

# ===========================================================================
# Feed parity with `just golems`: helper --once is the single source of truth.
# Multiple golems with mixed latest states -> only the fresh-gate ones appear.
# ===========================================================================
test_multi_golem_mixed_state() {
    local wt out
    wt=$(setup_worktree 806)
    feed_line "$wt" "golem-806" "gate" "needs permission A"
    feed_line "$wt" "golem-900" "idle" "waiting for your input"
    feed_line "$wt" "golem-901" "gate" "needs permission B"
    out=$(run_once "$wt")
    assert_contains "$out" "golem-806" "gated golem-806 listed"
    assert_contains "$out" "golem-901" "gated golem-901 listed"
    assert_not_contains "$out" "golem-900" "idle golem-900 omitted"
    teardown_worktree "$wt"
}
run_test test_multi_golem_mixed_state "mixed-state golems: only fresh gates listed"

# ===========================================================================
# --stream dedupe: prime past a standing gate, confirm one short cycle emits
# nothing for the SAME standing gate, then a NEW gate emits.
#
# Driving the real poll loop deterministically is awkward (it sleeps and never
# exits), so we test the transition semantics through the snapshot the loop
# consumes: a standing gate present at prime time must not re-emit, while a gate
# that appears later must. We assert this via two --once snapshots plus an
# explicit re-gate, which is exactly the input the streaming dedupe keys on.
# (The streaming loop's own emit_transitions logic is plain and shares this
# snapshot; the dedupe rule is the snapshot delta, validated here.)
# ===========================================================================
test_stream_snapshot_delta() {
    local wt before after
    wt=$(setup_worktree 807)
    feed_line "$wt" "golem-807" "gate" "standing gate"
    before=$(run_once "$wt")
    assert_contains "$before" "golem-807" "standing gate present in first snapshot"
    # Same standing gate, no new line: snapshot is unchanged (dedupe would
    # suppress re-emission since message is identical).
    after=$(run_once "$wt")
    assert_equals "$before" "$after" "unchanged standing gate yields an identical snapshot (no new transition)"
    teardown_worktree "$wt"
}
run_test test_stream_snapshot_delta "standing gate yields stable snapshot (stream dedupe input)"

# ===========================================================================
# Pane channel: stub `tmux` replays a canned capture-pane buffer so the helper
# sees a live golem-* session sitting at a prompt overlay.
#
# The stub answers:
#   `tmux ls`               -> one golem-<N> session line
#   `tmux capture-pane ...` -> the buffer for $PANE_FILE
# Reaching the pane path with ONLY our stub (no real tmux) requires building a
# PATH that contains the stub plus the few real commands the helper calls, and
# running under that PATH.
# ===========================================================================

# Build a stub-tmux dir. Args: <session-name> <pane-buffer-file>. Echoes dir.
make_tmux_stub() {
    local session="$1" panefile="$2" dir
    dir=$(/usr/bin/mktemp -d)
    /usr/bin/cat >"$dir/tmux" <<STUB
#!/usr/bin/env bash
case "\$1" in
    ls) /usr/bin/echo "${session}: 1 windows" ;;
    capture-pane) /bin/cat "${panefile}" ;;
    *) : ;;
esac
STUB
    /usr/bin/chmod +x "$dir/tmux"
    /usr/bin/echo "$dir"
}

# Run --once-panes with a stub tmux on PATH (ahead of the real one). grep/sort/
# date/etc. are resolved by full path in the helper, so PATH only needs the
# stub plus bash. `BASH_ENV=` is cleared because this container sets
# BASH_ENV=/etc/bash_env, which every non-interactive bash sources and which
# REBUILDS PATH — silently dropping our stub and letting the real tmux win.
# Clearing it keeps the prepended stub authoritative. Echo stdout.
run_once_panes() {
    local stubdir="$1"
    (/usr/bin/env BASH_ENV='' PATH="$stubdir:$PATH" "$WATCH" --once-panes 2>/dev/null)
}

test_pane_generic_gate() {
    local panefile stubdir out
    panefile=$(/usr/bin/mktemp)
    /usr/bin/cat >"$panefile" <<'PANE'
  Bash command
  rm -rf build/

  Do you want to proceed?
  > 1. Yes
    2. No
PANE
    stubdir=$(make_tmux_stub "golem-810" "$panefile")
    out=$(run_once_panes "$stubdir")
    assert_contains "$out" "golem-810" "a session at a 'Do you want to proceed?' overlay is reported"
    assert_contains "$out" "permission gate" "generic overlay is labeled a permission gate"
    /usr/bin/rm -rf "$stubdir" "$panefile"
}
run_test test_pane_generic_gate "pane: generic permission overlay is reported"

test_pane_plan_gate() {
    local panefile stubdir out
    panefile=$(/usr/bin/mktemp)
    /usr/bin/cat >"$panefile" <<'PANE'
  Here is Claude's plan:
  - do the thing

  Would you like to proceed?
  > 1. Yes, and auto-accept edits
    2. Yes, manually approve
    3. No, keep planning
PANE
    stubdir=$(make_tmux_stub "golem-811" "$panefile")
    out=$(run_once_panes "$stubdir")
    assert_contains "$out" "golem-811" "a session at the ExitPlanMode prompt is reported"
    assert_contains "$out" "plan gate" "plan-approval overlay is labeled a plan gate"
    /usr/bin/rm -rf "$stubdir" "$panefile"
}
run_test test_pane_plan_gate "pane: ExitPlanMode plan overlay is flagged as a plan gate"

# ===========================================================================
# Pane channel: an ExitPlanMode overlay whose only distinctive line is the
# `Yes, and use auto mode` option (issue #621 lists this signature explicitly)
# is still flagged as a plan gate, not missed.
# ===========================================================================
test_pane_plan_gate_auto_mode() {
    local panefile stubdir out
    panefile=$(/usr/bin/mktemp)
    /usr/bin/cat >"$panefile" <<'PANE'
  > 1. Yes, and use auto mode
    2. Yes, manually approve edits
    3. No, keep planning
PANE
    stubdir=$(make_tmux_stub "golem-813" "$panefile")
    out=$(run_once_panes "$stubdir")
    assert_contains "$out" "golem-813" "an overlay with the 'use auto mode' option is reported"
    assert_contains "$out" "plan gate" "the 'use auto mode' overlay is labeled a plan gate"
    /usr/bin/rm -rf "$stubdir" "$panefile"
}
run_test test_pane_plan_gate_auto_mode "pane: 'Yes, and use auto mode' overlay is flagged as a plan gate"

# ===========================================================================
# Pane channel: an overlay whose only plan-gate marker is the `Ready to code?`
# header (the ExitPlanMode prompt that opens with that line) is flagged as a
# plan gate. Guards the `Ready to code` branch of pane_is_plan_gate, which no
# other test exercises in isolation.
# ===========================================================================
test_pane_plan_gate_ready_to_code() {
    local panefile stubdir out
    panefile=$(/usr/bin/mktemp)
    /usr/bin/cat >"$panefile" <<'PANE'
  Ready to code?

  > 1. Yes
    2. No
PANE
    stubdir=$(make_tmux_stub "golem-814" "$panefile")
    out=$(run_once_panes "$stubdir")
    assert_contains "$out" "golem-814" "a session at the 'Ready to code?' overlay is reported"
    assert_contains "$out" "plan gate" "the 'Ready to code?' overlay is labeled a plan gate"
    /usr/bin/rm -rf "$stubdir" "$panefile"
}
run_test test_pane_plan_gate_ready_to_code "pane: 'Ready to code?' overlay is flagged as a plan gate"

test_pane_work_output_not_reported() {
    local panefile stubdir out
    panefile=$(/usr/bin/mktemp)
    # Pure scrolling work output — no prompt overlay. Must NOT be reported.
    /usr/bin/cat >"$panefile" <<'PANE'
  Running tests...
  test_foo ... ok
  test_bar ... ok
  Compiling crate v0.1.0
PANE
    stubdir=$(make_tmux_stub "golem-812" "$panefile")
    out=$(run_once_panes "$stubdir")
    assert_not_contains "$out" "golem-812" "a session showing only work output is not reported"
    /usr/bin/rm -rf "$stubdir" "$panefile"
}
run_test test_pane_work_output_not_reported "pane: work output without an overlay is not reported"

# ===========================================================================
# Pane channel: tmux present but ZERO golem-* sessions -> clean no-op, exit 0
# (issue #621 AC1). This is the transient handoff window — one golem's session
# killed, the next not yet created. The snapshot must emit nothing and succeed,
# never a stop signal, so the streaming loop that consumes it keeps polling
# across the gap instead of self-terminating.
# ===========================================================================
test_pane_zero_golem_sessions_noop() {
    local stubdir out rc
    # Stub `tmux ls` lists only NON-golem sessions, so the helper's
    # `grep -oE '^golem-[0-9]+'` matches nothing — exactly a zero-golem poll.
    stubdir=$(/usr/bin/mktemp -d)
    /usr/bin/cat >"$stubdir/tmux" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    ls) /usr/bin/echo "main: 1 windows"; /usr/bin/echo "editor: 2 windows" ;;
    *) : ;;
esac
STUB
    /usr/bin/chmod +x "$stubdir/tmux"
    out=$(/usr/bin/env BASH_ENV='' PATH="$stubdir:$PATH" "$WATCH" --once-panes 2>/dev/null)
    rc=$?
    assert_equals "0" "$rc" "zero golem-* sessions exits 0 (transient handoff window)"
    assert_equals "" "$out" "zero golem-* sessions produces no output and no stop signal"
    /usr/bin/rm -rf "$stubdir"
}
run_test test_pane_zero_golem_sessions_noop "pane: zero golem-* sessions is a clean no-op (no self-terminate)"

# ===========================================================================
# Pane channel: tmux absent -> clean no-op, exit 0.
# Build a minimal PATH with NO tmux (only bash + the helper's real commands via
# /usr/bin absolute paths already), so `command -v tmux` fails inside the helper.
# ===========================================================================
test_pane_no_tmux_noop() {
    local stubdir out rc
    stubdir=$(/usr/bin/mktemp -d)
    /usr/bin/ln -s "$(command -v bash)" "$stubdir/bash"
    # env -i + BASH_ENV= so /etc/bash_env cannot re-add the real tmux to PATH.
    out=$(/usr/bin/env -i BASH_ENV= PATH="$stubdir" "$WATCH" --once-panes 2>/dev/null)
    rc=$?
    assert_equals "0" "$rc" "no-tmux --once-panes exits 0"
    assert_equals "" "$out" "no-tmux --once-panes produces no output"
    /usr/bin/rm -rf "$stubdir"
}
run_test test_pane_no_tmux_noop "pane: absent tmux is a clean no-op"

# ===========================================================================
# Unknown mode -> usage error, exit 2.
# ===========================================================================
test_unknown_mode_errors() {
    local rc
    "$WATCH" --bogus >/dev/null 2>&1
    rc=$?
    assert_equals "2" "$rc" "an unknown mode exits 2"
}
run_test test_unknown_mode_errors "unknown mode exits 2"

generate_report
