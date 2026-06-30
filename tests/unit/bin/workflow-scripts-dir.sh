#!/usr/bin/env bash
# Unit tests for bin/workflow-scripts-dir.sh — resolution of the librarian
# `workflow` plugin's bundled scripts/ dir for the just-side golem recipes (#609).
#
# `just` runs outside Claude Code, where ${CLAUDE_PLUGIN_ROOT} is unset, so the
# thin-wrapper recipes resolve the bundled scripts through this helper. The
# resolution order (override > CLAUDE_PLUGIN_ROOT > newest installed cache > dev
# mount), and the "must actually contain config.sh" validity rule, are the
# contract these tests pin.

set -euo pipefail

# Hermetic: a pushing git hook can export GIT_* into this env (#599); irrelevant
# here, but cleared for parity with the sibling bin tests.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR GIT_PREFIX

source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

init_test_framework

test_suite "workflow-scripts-dir.sh — bundled-scripts resolution"

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/bin/workflow-scripts-dir.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
}

teardown() {
    if [ -n "${TEST_DIR:-}" ] && [ -d "$TEST_DIR" ]; then
        command rm -rf "$TEST_DIR"
    fi
}

# Make $1 look like a real bundled scripts dir (config.sh is the validity marker).
make_scripts_dir() {
    command mkdir -p "$1"
    command touch "$1/config.sh"
}

# Run the resolver with a clean, fully-controlled environment so a real
# CLAUDE_PLUGIN_ROOT / dev mount / HOME on the test machine never leaks in.
# Pass `VAR=value` assignments as args; HOME defaults to an empty TEST_DIR subdir
# so the installed-cache probe finds nothing, and WORKFLOW_DEV_MOUNT is pointed
# at a non-existent path so the last-resort dev-mount probe can't match a real
# /workspace/librarian checkout on the test machine — unless a test opts in.
run_resolver() {
    env -i \
        PATH="$PATH" \
        HOME="$TEST_DIR/empty-home" \
        WORKFLOW_DEV_MOUNT="$TEST_DIR/no-dev-mount" \
        "$@" \
        bash "$SCRIPT"
}

# ---------------------------------------------------------------------------
# 1. Explicit override wins and must be a valid scripts dir.
# ---------------------------------------------------------------------------
test_override_wins() {
    setup
    local d="$TEST_DIR/override"
    make_scripts_dir "$d"

    local got
    got="$(run_resolver "WORKFLOW_SCRIPTS_DIR=$d")"
    assert_equals "$d" "$got" "explicit WORKFLOW_SCRIPTS_DIR is returned verbatim"
    teardown
}

# ---------------------------------------------------------------------------
# 2. An override pointing at a dir WITHOUT config.sh is rejected (falls through);
#    with nothing else available, the resolver fails non-zero.
# ---------------------------------------------------------------------------
test_invalid_override_falls_through() {
    setup
    local d="$TEST_DIR/empty"
    command mkdir -p "$d" # no config.sh

    local rc=0
    run_resolver "WORKFLOW_SCRIPTS_DIR=$d" >/dev/null 2>&1 || rc=$?
    assert_not_equals "0" "$rc" "override without config.sh is not accepted"
    teardown
}

# ---------------------------------------------------------------------------
# 3. CLAUDE_PLUGIN_ROOT/scripts is used when no override is set.
# ---------------------------------------------------------------------------
test_plugin_root() {
    setup
    local root="$TEST_DIR/plugin"
    make_scripts_dir "$root/scripts"

    local got
    got="$(run_resolver "CLAUDE_PLUGIN_ROOT=$root")"
    assert_equals "$root/scripts" "$got" "CLAUDE_PLUGIN_ROOT/scripts is resolved"
    teardown
}

# ---------------------------------------------------------------------------
# 4. Installed marketplace cache: newest version dir wins (sort -V), and the
#    override / plugin-root both take precedence over it.
# ---------------------------------------------------------------------------
test_installed_cache_newest_wins() {
    setup
    local home="$TEST_DIR/home"
    local base="$home/.claude/plugins/cache/librarian/workflow"
    make_scripts_dir "$base/0.1.0/scripts"
    make_scripts_dir "$base/0.10.0/scripts" # newer; 0.10 > 0.2 only under -V
    make_scripts_dir "$base/0.2.0/scripts"

    # Pin WORKFLOW_DEV_MOUNT to a nonexistent path here too: this test bypasses
    # run_resolver's env -i, and a real /workspace/librarian dev mount would
    # otherwise satisfy the step-4 fallback if the cache probe failed (e.g. a
    # platform lacking `sort -V`), masking the assertion.
    local got
    got="$(env -i PATH="$PATH" HOME="$home" WORKFLOW_DEV_MOUNT="$TEST_DIR/no-dev-mount" bash "$SCRIPT")"
    assert_equals "$base/0.10.0/scripts" "$got" \
        "newest installed version is selected"
    teardown
}

# ---------------------------------------------------------------------------
# 4b. Cache loop skips a version whose scripts/ lacks config.sh and falls
#     through to the next-highest valid version (the is_scripts_dir guard).
# ---------------------------------------------------------------------------
test_installed_cache_skips_invalid_version() {
    setup
    local home="$TEST_DIR/home2"
    local base="$home/.claude/plugins/cache/librarian/workflow"
    command mkdir -p "$base/0.10.0/scripts" # highest, but NO config.sh -> skip
    make_scripts_dir "$base/0.2.0/scripts"  # next-highest, valid

    local got
    got="$(env -i PATH="$PATH" HOME="$home" WORKFLOW_DEV_MOUNT="$TEST_DIR/no-dev-mount" bash "$SCRIPT")"
    assert_equals "$base/0.2.0/scripts" "$got" \
        "a version dir without config.sh is skipped for the next valid one"
    teardown
}

# ---------------------------------------------------------------------------
# 4c. Dev-mount fallback (resolution step 4): a valid WORKFLOW_DEV_MOUNT is
#     accepted when no override / plugin-root / cache resolves. This is the
#     only path available when librarian is a compose dev mount, not installed.
# ---------------------------------------------------------------------------
test_dev_mount_fallback() {
    setup
    local d="$TEST_DIR/devmount"
    make_scripts_dir "$d"

    # Empty HOME so the cache probe finds nothing; no override, no plugin root.
    local got
    got="$(env -i PATH="$PATH" HOME="$TEST_DIR/empty-home" WORKFLOW_DEV_MOUNT="$d" bash "$SCRIPT")"
    assert_equals "$d" "$got" "valid WORKFLOW_DEV_MOUNT is accepted as the last resort"
    teardown
}

# ---------------------------------------------------------------------------
# 5. Nothing resolvable: exit non-zero, print nothing on stdout, guidance on
#    stderr.
# ---------------------------------------------------------------------------
test_not_found() {
    setup
    local out rc=0
    out="$(run_resolver 2>/dev/null)" || rc=$?
    assert_not_equals "0" "$rc" "resolver exits non-zero when nothing is found"
    assert_equals "" "$out" "resolver prints nothing on stdout when not found"

    local err
    err="$(run_resolver 2>&1 >/dev/null || true)"
    assert_contains "$err" "could not locate" "stderr carries guidance on failure"
    teardown
}

run_test test_override_wins
run_test test_invalid_override_falls_through
run_test test_plugin_root
run_test test_installed_cache_newest_wins
run_test test_installed_cache_skips_invalid_version
run_test test_dev_mount_fallback
run_test test_not_found

generate_report
