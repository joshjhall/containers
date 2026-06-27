#!/usr/bin/env bash
# Unit tests for bin/sync-host.sh — bare-host runtime-copy refresh from origin/main.
#
# Regression coverage for #606: a bare-repo host never checks files out, so its
# on-disk runtime copies (.claude/hooks, justfile, bin) drift behind origin/main
# after a merge and the host runs stale hooks/justfile. sync-host.sh refreshes
# those copies by writing each origin/main blob to disk (the manual remedy from
# the issue), with a --check drift guard and a --no-fetch offline mode.
#
# Each test builds a hermetic fixture: an "origin" working repo committed to
# main, plus a BARE host that adds origin as a remote and fetches it (so
# origin/main resolves exactly as on a real host). Stale on-disk copies are
# hand-placed at the host root, then sync-host runs with --no-fetch (the fixture
# origin is already fetched; no network).

set -euo pipefail

# Hermetic git environment. A pushing git hook exports GIT_DIR / GIT_INDEX_FILE
# etc. into this test's environment; left set, they hijack the fixtures' nested
# git commands back at the real repo (see #599). Clear them before any fixture
# git runs.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR GIT_PREFIX

# A fresh CI runner has no git identity configured, so the fixture's `git commit`
# would abort with "empty ident name" and leave origin/main unborn (the whole
# suite then errors out). Supply a hermetic identity via the environment so the
# fixtures commit without depending on the host's global git config.
export GIT_AUTHOR_NAME="sync-host-test" GIT_AUTHOR_EMAIL="sync-host-test@example.com"
export GIT_COMMITTER_NAME="sync-host-test" GIT_COMMITTER_EMAIL="sync-host-test@example.com"

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

init_test_framework

test_suite "sync-host.sh — bare-host runtime-copy refresh"

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/bin"
SYNC_SCRIPT="$BIN_DIR/sync-host.sh"
REPO_ROOT_SCRIPT="$BIN_DIR/repo-root.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
}

teardown() {
    # Leave the fixture before removing it so the shell cwd stays valid.
    cd / 2>/dev/null || true
    if [ -n "${TEST_DIR:-}" ] && [ -d "$TEST_DIR" ]; then
        command rm -rf "$TEST_DIR"
    fi
}

# Build a fixture: an origin repo with a small runtime set committed to main,
# and a bare host that fetched it. Sets globals $ORIGIN and $HOST (the host's
# work-root; its bare git dir is $HOST/.git). Leaves cwd at $HOST.
#
# The host's bin/ gets REAL copies of repo-root.sh and sync-host.sh so the
# script can resolve the root and run from the host exactly as in production.
make_fixture() {
    ORIGIN="$TEST_DIR/origin"
    command mkdir -p "$ORIGIN/.claude/hooks" "$ORIGIN/bin"
    command cp "$REPO_ROOT_SCRIPT" "$ORIGIN/bin/repo-root.sh"
    command cp "$SYNC_SCRIPT" "$ORIGIN/bin/sync-host.sh"
    (
        cd "$ORIGIN"
        git init -q -b main
        printf '#!/bin/sh\necho hook-v1\n' >.claude/hooks/golem-notify.sh
        command chmod +x .claude/hooks/golem-notify.sh
        printf 'default:\n\t@echo just-v1\n' >justfile
        command chmod +x bin/repo-root.sh bin/sync-host.sh
        git add -A
        git commit -qm init
    )

    HOST="$TEST_DIR/host"
    command mkdir -p "$HOST"
    git init -q --bare -b main "$HOST/.git"
    git --git-dir="$HOST/.git" remote add origin "$ORIGIN"
    git --git-dir="$HOST/.git" fetch -q origin

    # Hand-place the host's bin scripts (a bare host needs these on disk to run).
    command mkdir -p "$HOST/bin"
    git --git-dir="$HOST/.git" cat-file blob origin/main:bin/repo-root.sh >"$HOST/bin/repo-root.sh"
    git --git-dir="$HOST/.git" cat-file blob origin/main:bin/sync-host.sh >"$HOST/bin/sync-host.sh"
    command chmod +x "$HOST/bin/repo-root.sh" "$HOST/bin/sync-host.sh"
    cd "$HOST"
}

# Place stale on-disk copies of the hook + justfile at the host root.
place_stale() {
    command mkdir -p "$HOST/.claude/hooks"
    printf '#!/bin/sh\necho STALE\n' >"$HOST/.claude/hooks/golem-notify.sh"
    command chmod +x "$HOST/.claude/hooks/golem-notify.sh"
    printf 'default:\n\t@echo STALE\n' >"$HOST/justfile"
}

# ---------------------------------------------------------------------------
# 1. --check reports drift and exits non-zero when on-disk copies are stale.
# ---------------------------------------------------------------------------
test_check_reports_drift() {
    setup
    make_fixture
    place_stale

    local out rc=0
    out="$(bash "$HOST/bin/sync-host.sh" --check --no-fetch 2>&1)" || rc=$?
    assert_not_equals "0" "$rc" "--check exits non-zero when copies drift"
    assert_contains "$out" "golem-notify.sh" "--check names the drifted hook"
    assert_contains "$out" "justfile" "--check names the drifted justfile"
    teardown
}

# ---------------------------------------------------------------------------
# 2. A refresh rewrites the stale copies to match origin/main.
# ---------------------------------------------------------------------------
test_refresh_updates_stale_copies() {
    setup
    make_fixture
    place_stale

    local rc=0
    bash "$HOST/bin/sync-host.sh" --no-fetch >/dev/null 2>&1 || rc=$?
    assert_equals "0" "$rc" "refresh exits 0"

    assert_contains "$(command cat "$HOST/.claude/hooks/golem-notify.sh")" "hook-v1" \
        "hook content now matches origin/main"
    assert_contains "$(command cat "$HOST/justfile")" "just-v1" \
        "justfile content now matches origin/main"
    teardown
}

# ---------------------------------------------------------------------------
# 3. The executable bit from the tree mode is preserved (hook 0755, justfile
#    0644) — a hook written without +x would silently fail to fire.
# ---------------------------------------------------------------------------
test_refresh_preserves_exec_bit() {
    setup
    make_fixture
    place_stale

    bash "$HOST/bin/sync-host.sh" --no-fetch >/dev/null 2>&1

    assert_file_executable "$HOST/.claude/hooks/golem-notify.sh" \
        "refreshed hook keeps its executable bit"
    if [ -x "$HOST/justfile" ]; then
        fail_test "justfile must NOT be executable after refresh (tree mode 100644)"
    else
        pass_test "refreshed justfile is non-executable (matches tree mode)"
    fi
    teardown
}

# ---------------------------------------------------------------------------
# 4. After a refresh, --check reports in-sync and exits 0 (idempotent).
# ---------------------------------------------------------------------------
test_check_clean_after_refresh() {
    setup
    make_fixture
    place_stale

    bash "$HOST/bin/sync-host.sh" --no-fetch >/dev/null 2>&1

    local rc=0
    bash "$HOST/bin/sync-host.sh" --check --no-fetch >/dev/null 2>&1 || rc=$?
    assert_equals "0" "$rc" "--check exits 0 once copies match origin/main"
    teardown
}

# ---------------------------------------------------------------------------
# 5. A missing on-disk file is treated as drift and then created by a refresh.
# ---------------------------------------------------------------------------
test_missing_file_is_drift_then_created() {
    setup
    make_fixture
    # No place_stale: the host root has no hook/justfile at all.

    local rc=0
    bash "$HOST/bin/sync-host.sh" --check --no-fetch >/dev/null 2>&1 || rc=$?
    assert_not_equals "0" "$rc" "--check flags a missing runtime file as drift"

    bash "$HOST/bin/sync-host.sh" --no-fetch >/dev/null 2>&1
    assert_file_exists "$HOST/justfile" "refresh creates the missing justfile"
    assert_file_exists "$HOST/.claude/hooks/golem-notify.sh" \
        "refresh creates the missing hook"
    teardown
}

# ---------------------------------------------------------------------------
# 6. A path-prefix argument narrows the sync set: refreshing only `justfile`
#    leaves a separately-stale hook untouched.
# ---------------------------------------------------------------------------
test_prefix_narrows_set() {
    setup
    make_fixture
    place_stale

    bash "$HOST/bin/sync-host.sh" --no-fetch justfile >/dev/null 2>&1

    assert_contains "$(command cat "$HOST/justfile")" "just-v1" \
        "named prefix justfile was refreshed"
    assert_contains "$(command cat "$HOST/.claude/hooks/golem-notify.sh")" "STALE" \
        "unnamed hook prefix was left untouched"
    teardown
}

# ---------------------------------------------------------------------------
# 7. An unknown option is a usage error (exit 2), not a silent no-op.
# ---------------------------------------------------------------------------
test_unknown_option_errors() {
    setup
    make_fixture

    local rc=0
    bash "$HOST/bin/sync-host.sh" --bogus --no-fetch >/dev/null 2>&1 || rc=$?
    assert_equals "2" "$rc" "unknown option exits 2"
    teardown
}

run_test test_check_reports_drift
run_test test_refresh_updates_stale_copies
run_test test_refresh_preserves_exec_bit
run_test test_check_clean_after_refresh
run_test test_missing_file_is_drift_then_created
run_test test_prefix_narrows_set
run_test test_unknown_option_errors

generate_report
