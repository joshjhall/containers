#!/usr/bin/env bash
# Unit tests for lib/runtime/fuse-cleanup.sh
#
# The shared .fuse_hidden* garbage collector (issue #948). These tests are
# deliberately BEHAVIORAL rather than assert_file_contains static analysis: the
# bug being regressed was a `-maxdepth 3` bound, and no static assertion can
# catch a depth that is too shallow. The fixture in test_removes_nested_file is
# the load-bearing one — per the issue, a top-level fixture PASSES against the
# broken code, so only a file four components deep actually fails without the
# fix.
#
# The script is driven through FUSE_CLEANUP_ROOTS so the tests need no real FUSE
# mount. That override takes precedence over findmnt discovery ON PURPOSE and
# the tests depend on it: this project's own dev container mounts its workspace
# via bindfs, so a test that relied on "findmnt finds nothing" would instead
# hand the script the live source tree to sweep.

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "FUSE Hidden File Cleanup Tests"

# Source file under test
SOURCE_FILE="$PROJECT_ROOT/lib/runtime/fuse-cleanup.sh"

setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$TEST_SCRATCH_BASE/test-fuse-cleanup-$unique_id"
    command mkdir -p "$TEST_TEMP_DIR"
}

teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
    unset TEST_TEMP_DIR FUSE_CLEANUP_DISABLE FUSE_CLEANUP_ROOTS \
        FUSE_CLEANUP_FALLBACK_ROOT FUSE_CLEANUP_LOCK 2>/dev/null || true
}

run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"
    setup
    run_test "$test_function" "$test_description"
    teardown
}

# Run the GC against a scratch root, echoing its stdout (the cleaned count).
#
# The lock is pointed at a per-test scratch path (#950). Two reasons: the real
# /etc/container/lock/fuse-cleanup.lock does not exist on a bare test host, and
# on a host where it DOES exist a live container sweep holding it would make
# every behavioral test below skip its walk and assert against 0.
run_cleanup() {
    local root="$1"
    FUSE_CLEANUP_ROOTS="$root" FUSE_CLEANUP_LOCK="$TEST_TEMP_DIR/sweep.lock" \
        bash "$SOURCE_FILE"
}

# ============================================================================
# Static Analysis Tests
# ============================================================================

test_script_exists() {
    assert_file_exists "$SOURCE_FILE" "fuse-cleanup.sh exists"
}

test_syntax_valid() {
    if bash -n "$SOURCE_FILE" 2>&1; then
        pass_test "Script has valid bash syntax"
    else
        fail_test "Script has syntax errors"
    fi
}

test_no_maxdepth_bound() {
    # The entire point of #948: a depth bound is a guess about someone else's
    # directory layout. If one is ever reintroduced, this fails loudly next to
    # the behavioral tests that would also fail.
    #
    # Matches the find flag, not the bare word — the header comment explains the
    # bug being regressed and necessarily names -maxdepth.
    if command grep -qE '^[^#]*-maxdepth' "$SOURCE_FILE"; then
        fail_test "Walk is depth-bounded — -maxdepth reintroduced (issue #948)"
    else
        pass_test "Walk is not depth-bounded (issue #948)"
    fi
}

test_uses_findmnt_for_roots() {
    assert_file_contains "$SOURCE_FILE" "findmnt" \
        "Discovers roots via findmnt so both callers agree on the root"
}

test_checks_fuser() {
    assert_file_contains "$SOURCE_FILE" "fuser" \
        "Checks fuser before removing a hidden file"
}

test_honors_disable_gate() {
    assert_file_contains "$SOURCE_FILE" "FUSE_CLEANUP_DISABLE" \
        "Honors FUSE_CLEANUP_DISABLE"
}

# ============================================================================
# Behavioral Tests
# ============================================================================

test_removes_nested_file() {
    # THE regression test for #948. Four components below the root — the depth
    # at which plugins/<plugin>/scripts/.fuse_hiddenXXXX sits, and the depth the
    # old `-maxdepth 3` could not reach.
    command mkdir -p "$TEST_TEMP_DIR/a/b/c/d"
    local nested="$TEST_TEMP_DIR/a/b/c/d/.fuse_hiddenDEAD"
    : >"$nested"

    run_cleanup "$TEST_TEMP_DIR" >/dev/null

    assert_file_not_exists "$nested" \
        "Removes .fuse_hidden file nested 4 levels deep (issue #948)"
}

test_removes_deeply_nested_file() {
    # Well past any plausible depth bound — proves the walk is unbounded rather
    # than merely bounded at a larger number.
    command mkdir -p "$TEST_TEMP_DIR/l1/l2/l3/l4/l5/l6/l7/l8"
    local deep="$TEST_TEMP_DIR/l1/l2/l3/l4/l5/l6/l7/l8/.fuse_hiddenFEED"
    : >"$deep"

    run_cleanup "$TEST_TEMP_DIR" >/dev/null

    assert_file_not_exists "$deep" \
        "Removes .fuse_hidden file nested 8 levels deep"
}

test_removes_top_level_file() {
    # The flat case worked before the fix; make sure it still does.
    local flat="$TEST_TEMP_DIR/.fuse_hiddenBEEF"
    : >"$flat"

    run_cleanup "$TEST_TEMP_DIR" >/dev/null

    assert_file_not_exists "$flat" \
        "Removes top-level .fuse_hidden file (no regression on flat repos)"
}

test_prunes_git_directory() {
    # .git is pruned for cost, not correctness — but a prune that accidentally
    # swept it would be a nasty surprise, so pin the behavior.
    command mkdir -p "$TEST_TEMP_DIR/.git/objects"
    local in_git="$TEST_TEMP_DIR/.git/objects/.fuse_hiddenGIT1"
    : >"$in_git"

    run_cleanup "$TEST_TEMP_DIR" >/dev/null

    assert_file_exists "$in_git" \
        "Does not descend into .git (pruned)"
}

test_prunes_node_modules() {
    command mkdir -p "$TEST_TEMP_DIR/node_modules/pkg"
    local in_nm="$TEST_TEMP_DIR/node_modules/pkg/.fuse_hiddenNM01"
    : >"$in_nm"

    run_cleanup "$TEST_TEMP_DIR" >/dev/null

    assert_file_exists "$in_nm" \
        "Does not descend into node_modules (pruned)"
}

test_leaves_unrelated_files() {
    command mkdir -p "$TEST_TEMP_DIR/src/deep"
    local keep="$TEST_TEMP_DIR/src/deep/regular.txt"
    : >"$keep"

    run_cleanup "$TEST_TEMP_DIR" >/dev/null

    assert_file_exists "$keep" \
        "Leaves non-.fuse_hidden files untouched"
}

test_reports_cleaned_count() {
    command mkdir -p "$TEST_TEMP_DIR/x/y/z"
    : >"$TEST_TEMP_DIR/.fuse_hidden0001"
    : >"$TEST_TEMP_DIR/x/.fuse_hidden0002"
    : >"$TEST_TEMP_DIR/x/y/z/.fuse_hidden0003"

    local count
    count=$(run_cleanup "$TEST_TEMP_DIR")

    assert_equals "3" "$count" \
        "Reports the number of files removed on stdout"
}

test_reports_zero_when_clean() {
    command mkdir -p "$TEST_TEMP_DIR/empty"

    local count
    count=$(run_cleanup "$TEST_TEMP_DIR")

    assert_equals "0" "$count" \
        "Reports 0 when there is nothing to clean"
}

test_disable_gate_removes_nothing() {
    local flat="$TEST_TEMP_DIR/.fuse_hiddenSKIP"
    : >"$flat"

    local rc=0
    FUSE_CLEANUP_DISABLE=true FUSE_CLEANUP_ROOTS="$TEST_TEMP_DIR" \
        bash "$SOURCE_FILE" >/dev/null || rc=$?

    assert_equals "0" "$rc" "Exits 0 when disabled"
    assert_file_exists "$flat" \
        "FUSE_CLEANUP_DISABLE=true removes nothing"
}

# Build a findmnt stub that reports no FUSE mounts, so the fallback path can be
# exercised for real. Needed because this project's own dev container mounts its
# workspace via bindfs — the genuine findmnt returns that live tree.
#
# The stub is injected via FUSE_CLEANUP_FINDMNT rather than by prepending to
# PATH: the container's BASH_ENV rc files re-export PATH, so a prepended stub
# dir is silently dropped before the script under test ever runs.
# Echoes the stub's path.
stub_findmnt() {
    local stub_dir="$TEST_TEMP_DIR/stub-bin"
    command mkdir -p "$stub_dir"
    command printf '%s\n' '#!/bin/bash' 'exit 0' >"$stub_dir/findmnt"
    command chmod +x "$stub_dir/findmnt"
    echo "$stub_dir/findmnt"
}

test_fallback_root_is_used() {
    # The boot pass's path: no FUSE mounts, so the fallback root is swept —
    # and swept to full depth, like everything else.
    local sweep_root="$TEST_TEMP_DIR/workspace"
    command mkdir -p "$sweep_root/deep/er/still"
    local nested="$sweep_root/deep/er/still/.fuse_hiddenFB01"
    : >"$nested"

    local stub
    stub=$(stub_findmnt)

    FUSE_CLEANUP_FINDMNT="$stub" FUSE_CLEANUP_FALLBACK_ROOT="$sweep_root" \
        bash "$SOURCE_FILE" >/dev/null

    assert_file_not_exists "$nested" \
        "Sweeps FUSE_CLEANUP_FALLBACK_ROOT when no FUSE mount is found"
}

test_missing_root_exits_clean() {
    # A fallback root that does not exist must not error.
    local stub
    stub=$(stub_findmnt)

    local rc=0
    FUSE_CLEANUP_FINDMNT="$stub" FUSE_CLEANUP_FALLBACK_ROOT="$TEST_TEMP_DIR/does-not-exist" \
        bash "$SOURCE_FILE" >/dev/null || rc=$?

    assert_equals "0" "$rc" "Exits 0 when the fallback root does not exist"
}

test_no_root_configured_exits_clean() {
    local stub
    stub=$(stub_findmnt)

    local rc=0
    local out
    out=$(FUSE_CLEANUP_FINDMNT="$stub" bash "$SOURCE_FILE" 2>/dev/null) || rc=$?

    assert_equals "0" "$rc" "Exits 0 with no root configured"
    assert_equals "0" "$out" "Reports 0 with no root to sweep"
}

test_idempotent() {
    command mkdir -p "$TEST_TEMP_DIR/a/b/c/d"
    : >"$TEST_TEMP_DIR/a/b/c/d/.fuse_hiddenTWICE"

    run_cleanup "$TEST_TEMP_DIR" >/dev/null

    local second
    second=$(run_cleanup "$TEST_TEMP_DIR")

    assert_equals "0" "$second" \
        "Second run is a clean no-op (idempotent)"
}

# ============================================================================
# Overlap guard (issue #950)
# ============================================================================
# Behavioral, like everything else in this file: the property under test is
# "a second concurrent sweep does not walk", which no static assertion reaches.

# Hold a lock out-of-process for longer than any sweep here can take, setting
# LOCK_HOLDER_PID. Pass that to release_lock.
#
# The PID is returned in a GLOBAL, not echoed, on purpose. Under
# `holder=$(hold_lock ...)` the backgrounded holder inherits the command
# substitution's stdout pipe, so the substitution blocks until that fd closes —
# i.e. for the holder's full lifetime. The first version of this helper did
# exactly that: every "held lock" test silently waited out the 30s sleep and
# then swept an already-free lock, which reads as "the guard did not fire"
# rather than as a hang.
hold_lock() {
    local lock="$1"
    : >"$lock"
    flock "$lock" -c 'sleep 30' >/dev/null 2>&1 &
    local pid=$!
    # Wait for the lock to be genuinely held rather than sleeping a guessed
    # interval: a loaded runner can take longer than any fixed sleep, and the
    # race is silent (the sweep would "skip" a lock nobody holds and the test
    # would pass for the wrong reason).
    local waited=0
    while flock -n "$lock" -c true 2>/dev/null; do
        sleep 0.1
        waited=$((waited + 1))
        [ "$waited" -gt 100 ] && break
    done
    LOCK_HOLDER_PID="$pid"
}

# Release a lock taken by hold_lock.
#
# Killing the `flock` process alone is NOT enough, and getting this wrong is how
# test_sweeps_after_lock_released first failed: `flock <file> -c 'sleep 30'`
# runs the sleep as a CHILD that inherits the open fd, so killing the parent
# leaves the child holding the lock. Kill the children first, then the parent,
# then confirm the lock is actually free before returning.
release_lock() {
    local pid="$1" lock="$2"

    command pkill -P "$pid" 2>/dev/null || true
    command kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true

    local waited=0
    until flock -n "$lock" -c true 2>/dev/null; do
        sleep 0.1
        waited=$((waited + 1))
        [ "$waited" -gt 100 ] && break
    done
}

test_skips_when_lock_is_held() {
    # THE regression test for #950. A held lock must make the sweep a no-op —
    # and it must be a no-op on the WALK, not merely on the exit code, so the
    # fixture file has to survive.
    if ! command -v flock >/dev/null 2>&1; then
        skip_test "flock not available on this host"
        return
    fi

    command mkdir -p "$TEST_TEMP_DIR/a/b/c"
    local victim="$TEST_TEMP_DIR/a/b/c/.fuse_hiddenLOCK"
    : >"$victim"

    local lock="$TEST_TEMP_DIR/held.lock"
    local holder
    hold_lock "$lock"
    holder="$LOCK_HOLDER_PID"

    local count rc=0
    count=$(FUSE_CLEANUP_ROOTS="$TEST_TEMP_DIR" FUSE_CLEANUP_LOCK="$lock" \
        bash "$SOURCE_FILE") || rc=$?

    release_lock "$holder" "$lock"

    assert_equals "0" "$rc" "Exits 0 when another sweep holds the lock"
    assert_equals "0" "$count" "Reports 0 when another sweep holds the lock"
    assert_file_exists "$victim" \
        "Skips the walk entirely while the lock is held (issue #950)"
}

test_sweeps_after_lock_released() {
    # The other half: the guard must not be sticky. Once the holder is gone the
    # very next invocation sweeps normally — this is what makes "skip" safe,
    # since the skipped work is picked up on the next tick.
    if ! command -v flock >/dev/null 2>&1; then
        skip_test "flock not available on this host"
        return
    fi

    command mkdir -p "$TEST_TEMP_DIR/a/b/c"
    local victim="$TEST_TEMP_DIR/a/b/c/.fuse_hiddenAFTER"
    : >"$victim"

    local lock="$TEST_TEMP_DIR/released.lock"
    local holder
    hold_lock "$lock"
    holder="$LOCK_HOLDER_PID"
    release_lock "$holder" "$lock"

    local count
    count=$(FUSE_CLEANUP_ROOTS="$TEST_TEMP_DIR" FUSE_CLEANUP_LOCK="$lock" \
        bash "$SOURCE_FILE")

    assert_equals "1" "$count" "Sweeps normally once the lock is released"
    assert_file_not_exists "$victim" \
        "Removes the file the locked-out run skipped"
}

test_symlinked_lock_path_still_sweeps() {
    # Pins the `[ -L "$lock_path" ]` defence-in-depth branch — and pins it with a
    # fixture that DISCRIMINATES. A symlink whose target is free proves nothing:
    # the sweep runs whether or not the branch exists, so that version of this
    # test passes against the mutant with the branch deleted (verified).
    #
    # The fixture therefore reproduces what the branch actually defends against:
    # someone plants a symlink as the lock path and holds its TARGET. Following
    # the link would take flock on a held file, the sweep would skip, and the
    # planted link becomes an off switch for the GC. Refusing to follow it means
    # the sweep proceeds unlocked, which is contended but never suppressed.
    if ! command -v flock >/dev/null 2>&1; then
        skip_test "flock not available on this host"
        return
    fi

    command mkdir -p "$TEST_TEMP_DIR/deep/deeper"
    local victim="$TEST_TEMP_DIR/deep/deeper/.fuse_hiddenSYMLINK"
    : >"$victim"

    local target="$TEST_TEMP_DIR/planted-target.lock"
    local link="$TEST_TEMP_DIR/planted.lock"
    command ln -s "$target" "$link"

    local holder
    hold_lock "$target"
    holder="$LOCK_HOLDER_PID"

    local count
    count=$(FUSE_CLEANUP_ROOTS="$TEST_TEMP_DIR" FUSE_CLEANUP_LOCK="$link" \
        bash "$SOURCE_FILE")

    release_lock "$holder" "$target"

    assert_equals "1" "$count" \
        "Sweeps unlocked when the lock path is a symlink to a HELD file"
    assert_file_not_exists "$victim" \
        "A planted symlink cannot suppress the walk (defence in depth)"
}

test_unopenable_lock_path_still_sweeps() {
    # Degrade-to-unlocked, not degrade-to-refusing. A bare host has no
    # /etc/container/lock, and refusing to sweep there would turn a cost concern
    # back into the stranded-file bug #948 fixed. Must also be SILENT — the
    # shell's own "No such file or directory" on the fd redirect would otherwise
    # leak into the cron leg's output.
    command mkdir -p "$TEST_TEMP_DIR/deep/deeper"
    local victim="$TEST_TEMP_DIR/deep/deeper/.fuse_hiddenNOLOCK"
    : >"$victim"

    local stderr_file="$TEST_TEMP_DIR/stderr.txt"
    local count
    count=$(FUSE_CLEANUP_ROOTS="$TEST_TEMP_DIR" \
        FUSE_CLEANUP_LOCK="$TEST_TEMP_DIR/no-such-dir/sweep.lock" \
        bash "$SOURCE_FILE" 2>"$stderr_file")

    assert_equals "1" "$count" \
        "Sweeps unlocked when the lock path cannot be opened"
    assert_file_not_exists "$victim" \
        "An unopenable lock path does not suppress the walk"
    assert_equals "" "$(command cat "$stderr_file")" \
        "An unopenable lock path is silent on stderr"
}

test_lock_is_non_blocking() {
    # Distinguishes -n from -w. A queueing lock would make this invocation wait
    # out the holder; a non-blocking one returns immediately. The holder sleeps
    # 30s and the assertion allows 5s, so the margin is not tight enough to
    # flake on a loaded runner while still failing a genuine `flock -w`.
    if ! command -v flock >/dev/null 2>&1; then
        skip_test "flock not available on this host"
        return
    fi

    local lock="$TEST_TEMP_DIR/blocking.lock"
    local holder
    hold_lock "$lock"
    holder="$LOCK_HOLDER_PID"

    local start elapsed
    start=$(date +%s)
    FUSE_CLEANUP_ROOTS="$TEST_TEMP_DIR" FUSE_CLEANUP_LOCK="$lock" \
        bash "$SOURCE_FILE" >/dev/null
    elapsed=$(($(date +%s) - start))

    release_lock "$holder" "$lock"

    if [ "$elapsed" -lt 5 ]; then
        pass_test "Lock is non-blocking — returns immediately (${elapsed}s)"
    else
        fail_test "Lock queued behind the holder (${elapsed}s) — expected -n"
    fi
}

test_default_lock_path_is_documented_one() {
    # The default path is load-bearing: both callers rely on it being the SAME
    # file, and lib/features/bindfs.sh creates exactly this path at build time.
    assert_file_contains "$SOURCE_FILE" \
        'FUSE_CLEANUP_LOCK:-/etc/container/lock/fuse-cleanup.lock' \
        "Defaults to the documented /etc/container/lock/fuse-cleanup.lock"
}

test_lock_not_in_tmp() {
    # /tmp is world-writable, so a lock there can be pre-planted and held by any
    # local process — the reasoning already settled for claude-setup.lock (#943).
    if command grep -qE '^[^#]*FUSE_CLEANUP_LOCK.*/tmp/' "$SOURCE_FILE"; then
        fail_test "Lock path is under world-writable /tmp (cf. #943)"
    else
        pass_test "Lock path is not under /tmp"
    fi
}

test_handles_spaces_in_path() {
    # The walk is -print0/read -d '' end to end; a path with a space must
    # survive it.
    command mkdir -p "$TEST_TEMP_DIR/dir with space/nested"
    local spaced="$TEST_TEMP_DIR/dir with space/nested/.fuse_hiddenSPACE"
    : >"$spaced"

    run_cleanup "$TEST_TEMP_DIR" >/dev/null

    assert_file_not_exists "$spaced" \
        "Removes a .fuse_hidden file under a path containing spaces"
}

# ============================================================================
# Run all tests
# ============================================================================

# Static analysis
run_test test_script_exists "Script exists"
run_test test_syntax_valid "Script has valid bash syntax"
run_test test_no_maxdepth_bound "Walk is not depth-bounded"
run_test test_uses_findmnt_for_roots "Discovers roots via findmnt"
run_test test_checks_fuser "Checks fuser before removal"
run_test test_honors_disable_gate "Honors FUSE_CLEANUP_DISABLE"
run_test test_default_lock_path_is_documented_one "Default lock path is the documented one"
run_test test_lock_not_in_tmp "Lock path is not under /tmp"

# Behavioral tests
run_test_with_setup test_removes_nested_file "Removes file nested 4 deep (#948)"
run_test_with_setup test_removes_deeply_nested_file "Removes file nested 8 deep"
run_test_with_setup test_removes_top_level_file "Removes top-level file"
run_test_with_setup test_prunes_git_directory "Prunes .git"
run_test_with_setup test_prunes_node_modules "Prunes node_modules"
run_test_with_setup test_leaves_unrelated_files "Leaves unrelated files"
run_test_with_setup test_reports_cleaned_count "Reports cleaned count"
run_test_with_setup test_reports_zero_when_clean "Reports 0 when clean"
run_test_with_setup test_disable_gate_removes_nothing "Disable gate removes nothing"
run_test_with_setup test_fallback_root_is_used "Fallback root is swept"
run_test_with_setup test_missing_root_exits_clean "Missing root exits clean"
run_test_with_setup test_no_root_configured_exits_clean "No root configured exits clean"
run_test_with_setup test_idempotent "Idempotent"
run_test_with_setup test_handles_spaces_in_path "Handles spaces in paths"

# Overlap guard (#950)
run_test_with_setup test_skips_when_lock_is_held "Skips the walk while the lock is held (#950)"
run_test_with_setup test_sweeps_after_lock_released "Sweeps once the lock is released"
run_test_with_setup test_symlinked_lock_path_still_sweeps "Symlinked lock path degrades to unlocked"
run_test_with_setup test_unopenable_lock_path_still_sweeps "Unopenable lock path degrades to unlocked"
run_test_with_setup test_lock_is_non_blocking "Lock is non-blocking, not queueing"

# Generate test report
generate_report
