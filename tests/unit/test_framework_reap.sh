#!/usr/bin/env bash
# Tests for tf_reap_stale_temp_dirs (#817).
#
# The framework reaps abandoned per-test scratch directories from $TEST_SCRATCH_PARENT
# at init. Suites now name those directories uniquely, so a missed teardown
# leaks a NEW directory rather than reusing one name — measured at ~1,400 per
# full run, growing without bound (one tree reached 19,910 directories).
#
# This is a bulk `rm -rf`, so the properties that matter are what it must NOT
# delete: a concurrently-running suite's fresh tree, anything nested inside a
# scratch dir, and the scratch parent itself. Every assertion below therefore runs
# against a THROWAWAY scratch parent in a mktemp sandbox — never the real one,
# which holds this suite's own report while it runs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"
init_test_framework

FRAMEWORK_SH="$SCRIPT_DIR/../framework.sh"

test_suite "test framework stale-scratch reaper (#817)"

# ---------------------------------------------------------------------------
# Run the reaper in a CHILD shell against a sandbox scratch parent, so this
# suite's own scratch tree is never a target. Echoes the surviving entries,
# one per line, for the caller to assert against.
#
# BASH_ENV is cleared because it rebuilds PATH on non-interactive bash and
# would shadow the command lookups the framework relies on (see #618).
# ---------------------------------------------------------------------------
reap_in_sandbox() {
    local sandbox="$1"
    env -u BASH_ENV bash -c '
        set -euo pipefail
        source "$1"
        TEST_SCRATCH_PARENT="$2"
        tf_reap_stale_temp_dirs
        # List what survived (basename only, sorted for stable comparison).
        if [ -d "$TEST_SCRATCH_PARENT" ]; then
            command ls -1 "$TEST_SCRATCH_PARENT" 2>/dev/null | command sort
        else
            echo "__SCRATCH_PARENT_GONE__"
        fi
    ' _ "$FRAMEWORK_SH" "$sandbox"
}

new_sandbox() {
    command mktemp -d -t reap-test-XXXXXX
}

# Test: a stale directory is removed, a fresh one is not.
test_reaps_stale_keeps_fresh() {
    local sb survivors
    sb=$(new_sandbox)
    command mkdir -p "$sb/test-stale" "$sb/test-fresh"
    command touch -d '3 hours ago' "$sb/test-stale"

    survivors=$(reap_in_sandbox "$sb")

    assert_not_contains "$survivors" "test-stale" \
        "a scratch dir older than the cutoff is reaped"
    assert_contains "$survivors" "test-fresh" \
        "a fresh scratch dir — a concurrently running suite — is NOT reaped"
    command rm -rf "$sb"
}

run_test test_reaps_stale_keeps_fresh "reaps stale dirs, keeps fresh ones"

# Test: the cutoff boundary. 59 minutes must survive; 61 must not.
# `-mmin +60` means "more than 60 minutes", so 61 is the first reaped minute.
test_cutoff_boundary() {
    local sb survivors
    sb=$(new_sandbox)
    command mkdir -p "$sb/test-59min" "$sb/test-61min"
    command touch -d '59 minutes ago' "$sb/test-59min"
    command touch -d '61 minutes ago' "$sb/test-61min"

    survivors=$(reap_in_sandbox "$sb")

    assert_contains "$survivors" "test-59min" \
        "a dir just inside the cutoff survives"
    assert_not_contains "$survivors" "test-61min" \
        "a dir just past the cutoff is reaped"
    command rm -rf "$sb"
}

run_test test_cutoff_boundary "respects the 60-minute cutoff boundary"

# Test: contents of a FRESH dir are untouched. The reaper must never descend
# into a live suite's tree — maxdepth 1 is what stops it.
test_does_not_touch_fresh_contents() {
    local sb
    sb=$(new_sandbox)
    command mkdir -p "$sb/test-live/nested/deeper"
    echo "canary" >"$sb/test-live/nested/canary.txt"
    # An OLD file inside a FRESH dir must still survive: the age test applies
    # to the top-level scratch dir, never to what is inside one.
    command touch -d '5 hours ago' "$sb/test-live/nested/canary.txt"
    command touch -d '5 hours ago' "$sb/test-live/nested/deeper"

    reap_in_sandbox "$sb" >/dev/null

    assert_file_exists "$sb/test-live/nested/canary.txt" \
        "an old file inside a live scratch dir is not reaped"
    assert_equals "canary" "$(command cat "$sb/test-live/nested/canary.txt")" \
        "the live scratch dir's contents are intact"
    assert_dir_exists "$sb/test-live/nested/deeper" \
        "an old nested dir inside a live scratch dir is not reaped"
    command rm -rf "$sb"
}

run_test test_does_not_touch_fresh_contents "never descends into a live scratch tree"

# Test: the scratch parent itself survives, even when everything in it is stale AND
# the directory itself is older than the cutoff.
#
# Ageing the ROOT is what makes this test meaningful. `find <root> -maxdepth 1`
# matches the root itself, so without `-mindepth 1` the reaper would rm -rf
# the scratch parent out from under every running suite. A sandbox left at its
# mktemp-fresh mtime never crosses the cutoff, so the assertion would pass
# against a broken implementation — verified: the mindepth mutation survived
# until this test aged the root.
test_results_dir_itself_survives() {
    local sb survivors
    sb=$(new_sandbox)
    command mkdir -p "$sb/test-a" "$sb/test-b"
    command touch -d '3 hours ago' "$sb/test-a" "$sb/test-b"
    # The root last: creating entries inside it refreshes its mtime.
    command touch -d '3 hours ago' "$sb"

    survivors=$(reap_in_sandbox "$sb")

    assert_not_contains "$survivors" "__SCRATCH_PARENT_GONE__" \
        "the scratch parent itself is never removed (mindepth 1)"
    assert_dir_exists "$sb" "the results directory still exists after a full reap"
    command rm -rf "$sb"
}

run_test test_results_dir_itself_survives "never removes the scratch parent itself"

# Test: stale FILES are left alone — the reaper is scoped to directories, so a
# report file older than the cutoff is not collateral.
test_leaves_stale_files() {
    local sb survivors
    sb=$(new_sandbox)
    echo "report" >"$sb/test-report-old.txt"
    command touch -d '3 hours ago' "$sb/test-report-old.txt"

    survivors=$(reap_in_sandbox "$sb")

    assert_contains "$survivors" "test-report-old.txt" \
        "a stale FILE is not reaped (-type d scopes this to directories)"
    command rm -rf "$sb"
}

run_test test_leaves_stale_files "leaves stale files alone (-type d)"

# Test: a missing scratch parent is a clean no-op rather than an error. The
# function runs at init on every suite, so it must never be able to fail a run.
test_missing_results_dir_is_noop() {
    local sb rc=0
    sb=$(new_sandbox)
    command rm -rf "$sb"

    env -u BASH_ENV bash -c '
        set -euo pipefail
        source "$1"
        TEST_SCRATCH_PARENT="$2"
        tf_reap_stale_temp_dirs
    ' _ "$FRAMEWORK_SH" "$sb" >/dev/null 2>&1 || rc=$?

    assert_equals "0" "$rc" \
        "a missing scratch parent returns 0 — reaping must never redden a run"
}

run_test test_missing_results_dir_is_noop "no-ops safely when the scratch parent is absent"

# Test: an EMPTY scratch parent value must not send the reaper somewhere else.
# `[ -d "" ]` is false, so the guard returns before find is ever invoked.
test_empty_results_dir_is_noop() {
    local rc=0 out
    out=$(env -u BASH_ENV bash -c '
        set -euo pipefail
        source "$1"
        TEST_SCRATCH_PARENT=""
        tf_reap_stale_temp_dirs
        echo "returned"
    ' _ "$FRAMEWORK_SH" 2>&1) || rc=$?

    assert_equals "0" "$rc" "an empty scratch parent returns 0"
    assert_contains "$out" "returned" "an empty scratch parent is a clean no-op"
}

run_test test_empty_results_dir_is_noop "no-ops safely when the scratch parent is empty"

# Test: the reaper actually reaps. A silently-broken implementation returns 0
# and deletes nothing — which is exactly what the first version of this
# function did, because `command` is a shell builtin and is invalid inside
# find's -exec, so the whole expression failed with stderr suppressed.
test_reaper_is_not_silently_broken() {
    local sb survivors count
    sb=$(new_sandbox)
    local i
    for i in 1 2 3 4 5; do
        command mkdir -p "$sb/test-stale-$i"
        command touch -d '3 hours ago' "$sb/test-stale-$i"
    done

    survivors=$(reap_in_sandbox "$sb")
    count=$(command printf '%s' "$survivors" | command grep -c 'test-stale' || true)

    assert_equals "0" "$count" \
        "all stale dirs are actually removed, not just reported as handled"
    command rm -rf "$sb"
}

run_test test_reaper_is_not_silently_broken "actually deletes (guards the silent-failure regression)"

# Test: the reaper is actually WIRED into init_test_framework, and reached
# through the real entry point rather than only callable directly.
#
# Every test above calls tf_reap_stale_temp_dirs by hand, so all of them would
# still pass if init_test_framework stopped calling it — or called it before
# `mkdir -p "$TEST_SCRATCH_BASE"`, where the `[ -d ]` guard returns early on a first
# run. This drives the real entry point instead.
test_reaper_is_wired_into_init() {
    local sb out
    sb=$(new_sandbox)
    command mkdir -p "$sb/test-stale-wired"
    command touch -d '3 hours ago' "$sb/test-stale-wired"

    # init_test_framework() resets the suite's counters, so it is run in a
    # CHILD shell — the same reason test_framework_git_hermetic.sh does.
    # TEST_SCRATCH_PARENT is overridden AFTER sourcing so init reaps the sandbox.
    out=$(env -u BASH_ENV bash -c '
        set -euo pipefail
        source "$1"
        TEST_SCRATCH_PARENT="$2"
        SKIP_DOCKER_CHECK=true init_test_framework >/dev/null 2>&1
        command ls -1 "$TEST_SCRATCH_PARENT" 2>/dev/null | command sort
    ' _ "$FRAMEWORK_SH" "$sb")

    assert_not_contains "$out" "test-stale-wired" \
        "init_test_framework reaps stale dirs — the call is still wired up"
    command rm -rf "$sb"
}

run_test test_reaper_is_wired_into_init "init_test_framework calls the reaper"

generate_report
