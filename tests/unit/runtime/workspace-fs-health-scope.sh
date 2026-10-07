#!/usr/bin/env bash
# Unit tests for lib/runtime/42-workspace-fs-health.sh — exported-but-empty
# PROJECT_ROOT scope resolution (issues #828, #917).
#
# Split out of tests/unit/runtime/workspace-fs-health.sh in issue #917, which
# was over the file-length budget before the #917 diagnostic tests landed. The
# section is self-contained: it depends only on fixtures in the shared helper
# (seed_workspace, get_ignorecase_at, run_fs_health_workspace). The
# sibling-file shape follows workspace-fs-health-xattr.sh.

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Workspace FS Health PROJECT_ROOT Scope Tests"

# Shared fixtures: FS_HEALTH_SCRIPT, setup/teardown, seed_workspace,
# get_ignorecase_at, run_fs_health_workspace, run_test_with_setup.
# Sourced after init_test_framework — setup() reads TEST_SCRATCH_BASE.
source "$(dirname "${BASH_SOURCE[0]}")/../../framework/helpers/workspace-fs-health.sh"

# ============================================================================
# Exported-but-empty PROJECT_ROOT (issues #828, #917)
# ============================================================================
# The empty value pins single scope on the empty path, which is not a repo, so
# the run clears the cron snapshot and exits 0 — both repair legs off for the
# life of the container. That outcome is deliberate (#828); exiting SILENTLY
# was not (#917).

# Run the script with PROJECT_ROOT exported empty. Returns stderr.
# Args: $1 = workspace root
run_fs_health_empty_root() {
    (
        export PROJECT_ROOT=""
        export WORKSPACE_ROOT="$1"
        export FS_CASE_STATE=insensitive
        export FS_HEALTH_ENV_FILE
        { bash "$FS_HEALTH_SCRIPT" >/dev/null; } 2>&1
    )
}

test_exported_empty_project_root_stays_single_scope() {
    # The scope check reads ${PROJECT_ROOT+x} (SET, including empty) rather than
    # ${PROJECT_ROOT:-} (set AND non-empty), deliberately: an exported-but-empty
    # PROJECT_ROOT is a caller mistake, and pinning single scope on the empty
    # path surfaces it. Treating it as unset would instead silently scan the
    # whole workspace — writing to repos the caller never named.
    #
    # Without this test, "simplifying" +x back to :- would pass every other
    # test in the suite.
    seed_workspace

    # A snapshot left by an earlier boot. Without it the "cleared" assertion
    # below holds whether or not the empty-root branch removes anything.
    command mkdir -p "$(command dirname "$FS_HEALTH_ENV_FILE")"
    command echo "PROJECT_ROOT='/stale'" >"$FS_HEALTH_ENV_FILE"

    run_fs_health_empty_root "$WS_ROOT" >/dev/null

    assert_equals "unset" "$(get_ignorecase_at "$WS_ROOT/repo-a")" \
        "An exported-but-empty PROJECT_ROOT must not widen into a workspace scan"
    assert_equals "unset" "$(get_ignorecase_at "$WS_ROOT/repo-b")" \
        "No repo under the workspace should be touched on the empty-path branch"
    assert_file_not_exists "$FS_HEALTH_ENV_FILE" \
        "An empty PROJECT_ROOT should clear a stale snapshot (cron leg off)"
    unseed_workspace
}

test_exported_empty_project_root_is_reported() {
    # The exit above disables both legs, so it must not be indistinguishable
    # from a healthy run (issue #917) — the same reasoning as the #828 zero-repo
    # report. Pins both the variable name and the condition, so a generic
    # "nothing to inspect" line would not satisfy it.
    seed_workspace

    local output
    output=$(run_fs_health_empty_root "$WS_ROOT")

    assert_contains "$output" "PROJECT_ROOT is set but empty" \
        "An exported-but-empty PROJECT_ROOT is reported on stderr (issue #917)"
    assert_contains "$output" "$WS_ROOT" \
        "The report names the workspace root that unsetting would scan"
    unseed_workspace
}

test_exported_empty_project_root_exits_zero() {
    # Reporting must not turn an operator mistake into a failed container start.
    seed_workspace

    local rc=0
    run_fs_health_empty_root "$WS_ROOT" >/dev/null || rc=$?

    assert_equals "0" "$rc" \
        "An empty PROJECT_ROOT is reported, never fatal to startup"
    unseed_workspace
}

test_unset_project_root_emits_no_empty_diagnostic() {
    # The diagnostic keys on SET-but-empty. Unset is the default workspace scope
    # and must not trip it — otherwise every ordinary boot would print it.
    seed_workspace

    local output
    output=$(run_fs_health_workspace "$WS_ROOT" sensitive)

    assert_not_contains "$output" "set but empty" \
        "An unset PROJECT_ROOT is the workspace default, not the empty case"
    unseed_workspace
}

test_named_non_repo_emits_no_empty_diagnostic() {
    # A NON-empty PROJECT_ROOT that is not a repo takes the same bail-out, but
    # is not the empty case; the message must not misname it.
    local output
    output=$(
        export PROJECT_ROOT="$TEST_TEMP_DIR/not-a-repo"
        export FS_CASE_STATE=sensitive
        export FS_HEALTH_ENV_FILE
        command mkdir -p "$PROJECT_ROOT"
        { bash "$FS_HEALTH_SCRIPT" >/dev/null; } 2>&1
    )

    assert_not_contains "$output" "set but empty" \
        "A named non-repo root is not reported as an empty PROJECT_ROOT"
}

# ============================================================================
# Run all tests
# ============================================================================

run_test_with_setup test_exported_empty_project_root_stays_single_scope "Exported-but-empty PROJECT_ROOT stays single-scope"
run_test_with_setup test_exported_empty_project_root_is_reported "Exported-but-empty PROJECT_ROOT is reported (#917)"
run_test_with_setup test_exported_empty_project_root_exits_zero "Exported-but-empty PROJECT_ROOT still exits 0 (#917)"
run_test_with_setup test_unset_project_root_emits_no_empty_diagnostic "Unset PROJECT_ROOT does not trip the empty diagnostic (#917)"
run_test_with_setup test_named_non_repo_emits_no_empty_diagnostic "Named non-repo root does not trip the empty diagnostic (#917)"

# Generate test report
generate_report
