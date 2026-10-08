#!/usr/bin/env bash
# Unit tests for how lib/runtime/42-workspace-fs-health.sh loads its sourced
# fragment, lib/runtime/lib/workspace-fs-health-repo-tree.sh (issue #1090).
#
# The repo-tree checks themselves are covered by the sibling suites, which run
# the script from the source tree and so exercise the fragment unchanged. This
# suite pins only the LOADING contract:
#
#   - the path comes from fixed locations, never the environment (#968's rule)
#   - a missing fragment reports and exits 0, never failing container startup
#   - the moved functions really did move (the split cannot silently revert)

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Workspace Filesystem Health Fragment Loading Tests"

# Shared fixtures: FS_HEALTH_SCRIPT, setup/teardown, run_fs_health,
# run_fs_health_stderr, get_ignorecase, run_test_with_setup.
source "$(dirname "${BASH_SOURCE[0]}")/../../framework/helpers/workspace-fs-health.sh"

FS_HEALTH_FRAGMENT="$(dirname "$FS_HEALTH_SCRIPT")/lib/workspace-fs-health-repo-tree.sh"

# Copy the script into a scratch dir with NO lib/ sibling, and rewrite the
# installed-path fallback in that COPY to a path that cannot exist. Neither
# fixed location then resolves, which is the only way to reach the
# missing-fragment branch now that no environment variable can choose the path.
#
# Fails loudly when the rewrite matches nothing: a silent no-op would leave the
# copy pointing at the real /opt/container-runtime/lib, and on an image where
# that exists the test would pass for the wrong reason.
#
# Args: $1 = directory to stand in for /opt/container-runtime/lib (default: one
# that does not exist). Echoes the path to the copy.
make_fragmentless_copy() {
    local dir="$TEST_TEMP_DIR/no-lib"
    local copy="$dir/42-workspace-fs-health.sh"
    local fallback='"/opt/container-runtime/lib/workspace-fs-health-repo-tree.sh"'
    local installed_lib="${1:-$dir/does-not-exist}"

    command mkdir -p "$dir"
    command cp "$FS_HEALTH_SCRIPT" "$copy"

    if ! command grep -qF "$fallback" "$copy"; then
        command echo "fallback line not found in $FS_HEALTH_SCRIPT" >&2
        return 1
    fi
    command sed -i "s|${fallback}|\"$installed_lib/workspace-fs-health-repo-tree.sh\"|" "$copy"
    if command grep -qF "$fallback" "$copy"; then
        command echo "fallback rewrite did not apply in $copy" >&2
        return 1
    fi

    command echo "$copy"
}

# ============================================================================
# Fragment loading
# ============================================================================

test_fragment_exists_and_parses() {
    assert_file_exists "$FS_HEALTH_FRAGMENT" "Fragment ships beside the script under lib/"
    local rc=0
    bash -n "$FS_HEALTH_FRAGMENT" 2>/dev/null || rc=$?
    assert_exit_code 0 "$rc" "Fragment parses"
}

test_moved_functions_not_defined_in_main_script() {
    local fn defined=""
    for fn in check_ignorecase symlink_stale_reason check_symlinks \
        check_symlink_xattr check_stale_index_lock repair_repo_tree; do
        if command grep -qE "^${fn}\(\)" "$FS_HEALTH_SCRIPT"; then
            defined="$defined $fn"
        fi
        if ! command grep -qE "^${fn}\(\)" "$FS_HEALTH_FRAGMENT"; then
            fail_test "$fn is not defined in the fragment"
            return
        fi
    done
    assert_empty "$defined" "Moved functions must live only in the fragment"
}

test_missing_fragment_reports_and_exits_zero() {
    local copy rc=0 stderr
    copy=$(make_fragmentless_copy) || {
        fail_test "Could not build a fragmentless copy of the script"
        return
    }

    stderr=$( (
        export PROJECT_ROOT FS_HEALTH_ENV_FILE
        export FS_CASE_STATE=insensitive
        { bash "$copy" >/dev/null; } 2>&1
    )) || rc=$?

    assert_exit_code 0 "$rc" "A missing fragment must never fail startup"
    assert_contains "$stderr" "workspace-fs-health-repo-tree.sh not found" \
        "A missing fragment is reported, not silent"
    assert_equals "unset" "$(get_ignorecase)" \
        "No repair runs without the fragment"
}

test_installed_fallback_location_loads_fragment() {
    # The INSTALLED layout: the Dockerfile copies the script alone into
    # /etc/container/startup/, so it has no lib/ sibling and must reach the
    # fragment through the second fixed location. Stand that location in with a
    # scratch dir holding the real fragment, and require the repair to run.
    local copy installed="$TEST_TEMP_DIR/installed-lib" stderr
    command mkdir -p "$installed"
    command cp "$FS_HEALTH_FRAGMENT" "$installed/"
    copy=$(make_fragmentless_copy "$installed") || {
        fail_test "Could not build a fragmentless copy of the script"
        return
    }
    assert_file_not_exists "$(dirname "$copy")/lib/workspace-fs-health-repo-tree.sh" \
        "The copy must have no lib/ sibling, or this tests the first location"

    stderr=$( (
        export PROJECT_ROOT FS_HEALTH_ENV_FILE
        export FS_CASE_STATE=insensitive
        { bash "$copy" >/dev/null; } 2>&1
    )) || true

    assert_not_contains "$stderr" "not found" \
        "The fallback location must resolve the fragment"
    assert_equals "true" "$(get_ignorecase)" \
        "Repairs run when the fragment is found only at the installed location"
}

test_env_cannot_choose_fragment_path() {
    # A marker-writing file planted where an env override would point. The
    # script has no such override; this pins that one is never added back.
    local planted="$TEST_TEMP_DIR/planted-fragment.sh"
    local marker="$TEST_TEMP_DIR/planted-was-sourced"
    command printf 'command touch %q\n' "$marker" >"$planted"

    (
        export FS_HEALTH_REPO_TREE_LIB="$planted"
        run_fs_health insensitive
    ) || true

    assert_file_not_exists "$marker" \
        "An exported FS_HEALTH_REPO_TREE_LIB must never be sourced"
    assert_equals "true" "$(get_ignorecase)" \
        "The real fragment still loads and repairs"
}

test_env_cannot_choose_fragment_path_when_fragment_missing() {
    # Same plant, but with both fixed locations absent — the one state where an
    # env fallback would be most tempting to add.
    local copy planted="$TEST_TEMP_DIR/planted-fragment.sh"
    local marker="$TEST_TEMP_DIR/planted-was-sourced"
    command printf 'command touch %q\n' "$marker" >"$planted"
    copy=$(make_fragmentless_copy) || {
        fail_test "Could not build a fragmentless copy of the script"
        return
    }

    (
        export PROJECT_ROOT FS_HEALTH_ENV_FILE
        export FS_CASE_STATE=insensitive
        export FS_HEALTH_REPO_TREE_LIB="$planted"
        bash "$copy"
    ) >/dev/null 2>&1 || true

    assert_file_not_exists "$marker" \
        "An exported FS_HEALTH_REPO_TREE_LIB must never be sourced, even as a fallback"
}

# Run tests
run_test_with_setup test_fragment_exists_and_parses "Fragment exists and parses"
run_test_with_setup test_moved_functions_not_defined_in_main_script "Repo-tree functions live only in the fragment"
run_test_with_setup test_missing_fragment_reports_and_exits_zero "Missing fragment reports and exits 0"
run_test_with_setup test_installed_fallback_location_loads_fragment "Installed fallback location loads the fragment"
run_test_with_setup test_env_cannot_choose_fragment_path "Env var cannot choose the fragment path"
run_test_with_setup test_env_cannot_choose_fragment_path_when_fragment_missing "Env var is not a fallback when the fragment is missing"

# Generate test report
generate_report
