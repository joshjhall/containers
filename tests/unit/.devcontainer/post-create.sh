#!/usr/bin/env bash
# Unit tests for .devcontainer/post-create.sh
# Tests one-time devcontainer setup and the image/compose drift check

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Devcontainer Post-Create Tests"

# Run the real post-create.sh with `lefthook` stubbed out so the test never
# rewrites the live .git/hooks (shared with the main checkout from a worktree).
# BASH_ENV is unset because the container's /etc/bash_env re-prepends system
# dirs to PATH, which would let the real lefthook shadow the stub.
_run_post_create() {
    local stub="$TEST_TEMP_DIR/stub-bin"
    command mkdir -p "$stub"
    command printf '#!/bin/sh\nexit 0\n' >"$stub/lefthook"
    command chmod +x "$stub/lefthook"
    command env -u BASH_ENV PATH="$stub:$PATH" "$@" bash "$PROJECT_ROOT/.devcontainer/post-create.sh"
}

# Test: Script exists and is executable
test_script_exists() {
    assert_file_exists "$PROJECT_ROOT/.devcontainer/post-create.sh"
    assert_executable "$PROJECT_ROOT/.devcontainer/post-create.sh"
}

# Test: Lefthook config exists
test_lefthook_config_exists() {
    assert_file_exists "$PROJECT_ROOT/lefthook.yml"
}

# Test: Lefthook config has shellcheck hook
test_lefthook_has_shellcheck() {
    local config_file="$PROJECT_ROOT/lefthook.yml"

    if command grep -q "shellcheck" "$config_file"; then
        assert_true true "Lefthook config includes shellcheck"
    else
        assert_true false "Lefthook config missing shellcheck"
    fi
}

# Test: Lefthook config has unit tests in pre-push stage
test_lefthook_has_unit_tests() {
    local config_file="$PROJECT_ROOT/lefthook.yml"

    if command grep -q "unit-tests:" "$config_file" && command grep -q "pre-push:" "$config_file"; then
        assert_true true "Lefthook config includes unit tests on pre-push"
    else
        assert_true false "Lefthook config missing unit tests on pre-push"
    fi
}

# Test: Lefthook config has credential detection (gitleaks + detect-private-key)
test_lefthook_has_credential_detection() {
    local config_file="$PROJECT_ROOT/lefthook.yml"

    if command grep -q "gitleaks\|detect-private-key" "$config_file"; then
        assert_true true "Lefthook config includes credential detection"
    else
        assert_true false "Lefthook config missing credential detection"
    fi
}

# Test: Lefthook config prevents .env commit
test_lefthook_prevents_env_commit() {
    local config_file="$PROJECT_ROOT/lefthook.yml"

    if command grep -q "no-env-file\|\.env" "$config_file"; then
        assert_true true "Lefthook config prevents .env commit"
    else
        assert_true false "Lefthook config missing .env prevention"
    fi
}

# Test: .gitignore contains .env
test_gitignore_has_env() {
    if command grep -qF "**/.env" "$PROJECT_ROOT/.gitignore"; then
        assert_true true ".gitignore contains .env entry"
    else
        assert_true false ".gitignore missing .env entry"
    fi
}

# Test: Setup script uses lefthook install
test_script_uses_lefthook_install() {
    local script="$PROJECT_ROOT/.devcontainer/post-create.sh"

    if command grep -q "lefthook install" "$script"; then
        assert_true true "Setup script uses lefthook install"
    else
        assert_true false "Setup script doesn't use lefthook install"
    fi
}

# Test: Setup script installs both pre-commit and pre-push (lefthook install does both)
test_script_installs_hooks() {
    local script="$PROJECT_ROOT/.devcontainer/post-create.sh"

    if command grep -q "pre-commit.*pre-push\|lefthook install" "$script"; then
        assert_true true "Setup script installs both commit and push hooks via lefthook"
    else
        assert_true false "Setup script doesn't install lefthook hooks"
    fi
}

# Test: Setup script has color variables (sourced or defined)
test_script_has_colors() {
    local script="$PROJECT_ROOT/.devcontainer/post-create.sh"

    if command grep -q "colors.sh" "$script" || { command grep -q "RED=" "$script" && command grep -q "GREEN=" "$script"; }; then
        assert_true true "Setup script sources or defines color variables"
    else
        assert_true false "Setup script missing color variables"
    fi
}

# Test: Setup script checks .gitignore
test_script_checks_gitignore() {
    local script="$PROJECT_ROOT/.devcontainer/post-create.sh"

    if command grep -q "check-ignore -q .env" "$script"; then
        assert_true true "Setup script checks .gitignore"
    else
        assert_true false "Setup script doesn't check .gitignore"
    fi
}

# Test: Setup script has tool checking function
test_script_has_tool_checker() {
    local script="$PROJECT_ROOT/.devcontainer/post-create.sh"

    if command grep -q "check_tool()" "$script"; then
        assert_true true "Setup script has check_tool function"
    else
        assert_true false "Setup script missing check_tool function"
    fi
}

# Test: a MISSING recommended tool must NOT fail the script.
#
# post-create.sh runs under `set -euo pipefail` as the postCreateCommand, and
# VS Code skips postStartCommand when postCreateCommand fails — so a
# `return 1` from check_tool on a missing tool would skip setup-git/setup-gh
# and leave the container without git identity + SSH auth keys. See
# docs/troubleshooting/zed-devcontainer.md (chain-abort gotcha).
#
# The script sources $PROJECT_ROOT/lib/shared/colors.sh and cd's to
# PROJECT_ROOT (both derived from BASH_SOURCE), so it must run in place. In
# CI/dev images at least one recommended tool (docker in a no-INCLUDE_DOCKER
# build, or git-cliff/biome) is commonly absent, so this exercises the missing
# branch; even with all present, a regressed `return 1` on the LAST check_tool
# call still aborts the script under set -e, which this catches.
test_missing_recommended_tool_is_non_fatal() {
    local rc=0

    _run_post_create >/dev/null 2>&1 || rc=$?

    if [ "$rc" -eq 0 ]; then
        assert_true true "Setup script exits 0 (recommended-tool checks are non-fatal)"
    else
        assert_true false "Setup script exited $rc — a failing postCreateCommand skips postStartCommand"
    fi
}

# --- image/compose drift check ---------------------------------------------
#
# check_image_drift is exercised against fixtures by sourcing post-create.sh
# (its source guard keeps main from running).

_drift_fixture_dir() {
    local dir="$TEST_TEMP_DIR/drift"
    command mkdir -p "$dir"
    command cat >"$dir/compose.yml" <<'YAML'
services:
  devcontainer:
    build:
      args:
        INCLUDE_DEV_TOOLS: "true"
        # Node.js
        INCLUDE_NODE: "true"
        INCLUDE_RUST_DEV: "true"
        INCLUDE_PYTHON_DEV: false
        INCLUDE_GOLANG_DEV: 'true'
YAML
    command echo "$dir"
}

# Runs check_image_drift in a subshell; prints its output, then "rc=<N>".
_run_drift() {
    local compose=$1 conf=$2
    (
        # shellcheck source=/dev/null
        source "$PROJECT_ROOT/.devcontainer/post-create.sh"
        set +e
        check_image_drift "$compose" "$conf"
        echo "rc=$?"
    ) 2>&1
}

test_drift_clean_when_image_matches() {
    local dir out
    dir=$(_drift_fixture_dir)
    command printf '%s\n' INCLUDE_DEV_TOOLS=true INCLUDE_RUST_DEV=true INCLUDE_PYTHON_DEV=false >"$dir/features.conf"

    out=$(_run_drift "$dir/compose.yml" "$dir/features.conf")

    assert_contains "$out" "rc=0" "Matching image returns 0"
    assert_not_contains "$out" "STALE" "Matching image prints no stale warning"
}

test_drift_warns_on_mismatch() {
    local dir out
    dir=$(_drift_fixture_dir)
    command printf '%s\n' INCLUDE_DEV_TOOLS=true INCLUDE_RUST_DEV=false INCLUDE_PYTHON_DEV=false >"$dir/features.conf"

    out=$(_run_drift "$dir/compose.yml" "$dir/features.conf")

    assert_contains "$out" "rc=1" "Drifted image returns 1"
    assert_contains "$out" "IMAGE IS STALE" "Drifted image prints the stale warning"
    assert_contains "$out" "INCLUDE_RUST_DEV: compose=true image=false" "Warning names the mismatched key"
    assert_not_contains "$out" "INCLUDE_DEV_TOOLS:" "Matching keys are not listed"
}

test_drift_parses_single_quoted_values() {
    local dir out
    dir=$(_drift_fixture_dir)
    command printf '%s\n' INCLUDE_GOLANG_DEV=false >"$dir/features.conf"

    out=$(_run_drift "$dir/compose.yml" "$dir/features.conf")

    assert_contains "$out" "INCLUDE_GOLANG_DEV: compose=true image=false" "Single-quoted compose value is parsed"
}

test_drift_ignores_keys_absent_from_conf() {
    local dir out
    dir=$(_drift_fixture_dir)
    # INCLUDE_NODE is in compose but enabled-features.conf does not record it.
    command printf '%s\n' INCLUDE_DEV_TOOLS=true INCLUDE_RUST_DEV=true INCLUDE_PYTHON_DEV=false >"$dir/features.conf"

    out=$(_run_drift "$dir/compose.yml" "$dir/features.conf")

    assert_contains "$out" "rc=0" "Keys missing from the conf are not drift"
    assert_not_contains "$out" "INCLUDE_NODE:" "Unrecorded key is not reported as a mismatch"
    # ...but it is surfaced as unchecked, so a clean result does not overclaim.
    assert_contains "$out" "Not checked (image does not record):" "Unrecorded keys are listed as not checked"
    assert_contains "$out" "INCLUDE_NODE" "INCLUDE_NODE is among the unchecked keys"
    assert_contains "$out" "on 3 recorded INCLUDE_* flag(s)" "Clean result states how many flags were compared"
}

test_drift_skips_when_conf_missing() {
    local dir out
    dir=$(_drift_fixture_dir)

    out=$(_run_drift "$dir/compose.yml" "$dir/no-such.conf")

    assert_contains "$out" "rc=0" "Missing conf returns 0"
    assert_contains "$out" "skipping image drift check" "Missing conf prints a skip note"
}

test_drift_skips_when_compose_missing() {
    local dir out
    dir=$(_drift_fixture_dir)
    command printf '%s\n' INCLUDE_RUST_DEV=true >"$dir/features.conf"

    out=$(_run_drift "$dir/no-such.yml" "$dir/features.conf")

    assert_contains "$out" "rc=0" "Missing compose file returns 0"
    assert_contains "$out" "skipping image drift check" "Missing compose file prints a skip note"
}

# Drift must warn, never fail: the whole script still exits 0 (see the
# missing-tool test above for why a failing postCreateCommand is worse).
test_drift_does_not_fail_script() {
    local dir rc=0 out
    dir=$(_drift_fixture_dir)
    command printf '%s\n' INCLUDE_RUST_DEV=false >"$dir/features.conf"

    out=$(_run_post_create ENABLED_FEATURES_CONF="$dir/features.conf" 2>&1) || rc=$?

    assert_equals "0" "$rc" "post-create.sh exits 0 even when the image drifts"
    assert_contains "$out" "IMAGE IS STALE" "post-create.sh surfaces the drift warning"
}

# Test: the real compose file's INCLUDE_* args are parseable by the check
test_drift_parses_real_compose() {
    local dir out
    dir="$TEST_TEMP_DIR/real"
    command mkdir -p "$dir"
    # Claim the opposite of whatever compose says for RUST_DEV → must drift.
    command printf '%s\n' INCLUDE_RUST_DEV=false >"$dir/features.conf"

    out=$(_run_drift "$PROJECT_ROOT/.devcontainer/docker-compose.yml" "$dir/features.conf")

    assert_contains "$out" "INCLUDE_RUST_DEV: compose=true image=false" "Real compose INCLUDE_RUST_DEV is detected"
}

# Test: devcontainer.json wires both hooks in array form
test_devcontainer_json_wires_hooks() {
    local json
    json=$(command cat "$PROJECT_ROOT/.devcontainer/devcontainer.json")

    # Literal match (assert_file_contains takes a regex; `[` would misparse).
    assert_contains "$json" '"postCreateCommand": ["bash", ".devcontainer/post-create.sh"]' \
        "postCreateCommand runs post-create.sh (array form)"
    assert_contains "$json" '"postStartCommand": ["bash", ".devcontainer/post-start.sh"]' \
        "postStartCommand runs post-start.sh (array form)"
}

test_old_scripts_removed() {
    assert_file_not_exists "$PROJECT_ROOT/.devcontainer/bin/setup-dev-environment.sh"
    assert_file_not_exists "$PROJECT_ROOT/.devcontainer/rebuild.sh"
}

# Test: Setup script checks for shellcheck
test_script_checks_shellcheck() {
    local script="$PROJECT_ROOT/.devcontainer/post-create.sh"

    if command grep -q 'check_tool.*shellcheck' "$script"; then
        assert_true true "Setup script checks for shellcheck"
    else
        assert_true false "Setup script doesn't check for shellcheck"
    fi
}

# Test: Setup script checks for docker
test_script_checks_docker() {
    local script="$PROJECT_ROOT/.devcontainer/post-create.sh"

    if command grep -q 'check_tool.*docker' "$script"; then
        assert_true true "Setup script checks for docker"
    else
        assert_true false "Setup script doesn't check for docker"
    fi
}

# Test: Setup script checks for lefthook
test_script_checks_lefthook() {
    local script="$PROJECT_ROOT/.devcontainer/post-create.sh"

    if command grep -q 'check_tool.*lefthook\|command -v lefthook' "$script"; then
        assert_true true "Setup script checks for lefthook"
    else
        assert_true false "Setup script doesn't check for lefthook"
    fi
}

# Test: Setup script checks git user configuration
test_script_checks_git_config() {
    local script="$PROJECT_ROOT/.devcontainer/post-create.sh"

    if command grep -q "git config user.name" "$script" || command grep -q "git config user.email" "$script"; then
        assert_true true "Setup script checks git user configuration"
    else
        assert_true false "Setup script doesn't check git config"
    fi
}

# Test: No .githooks directory (lefthook installs hooks directly into .git/hooks)
test_no_githooks_directory() {
    if [ ! -d "$PROJECT_ROOT/.githooks" ]; then
        assert_true true "No .githooks directory (lefthook manages .git/hooks directly)"
    else
        assert_true false ".githooks directory still exists (should use lefthook)"
    fi
}

# Test: No lingering pre-commit config (migrated to lefthook)
test_no_precommit_config() {
    if [ ! -f "$PROJECT_ROOT/.pre-commit-config.yaml" ]; then
        assert_true true "No .pre-commit-config.yaml (migrated to lefthook.yml)"
    else
        assert_true false ".pre-commit-config.yaml still exists (should be removed post-migration)"
    fi
}

# Run tests
run_test test_script_exists "Setup script exists and is executable"
run_test test_lefthook_config_exists "Lefthook config exists"
run_test test_lefthook_has_shellcheck "Lefthook config includes shellcheck"
run_test test_lefthook_has_unit_tests "Lefthook config includes unit tests on pre-push"
run_test test_lefthook_has_credential_detection "Lefthook config includes credential detection"
run_test test_lefthook_prevents_env_commit "Lefthook config prevents .env commit"
run_test test_gitignore_has_env ".gitignore contains .env"
run_test test_script_uses_lefthook_install "Setup script uses lefthook install"
run_test test_script_installs_hooks "Setup script installs lefthook hooks"
run_test test_script_has_colors "Setup script has color variables"
run_test test_script_checks_gitignore "Setup script checks .gitignore"
run_test test_script_has_tool_checker "Setup script has check_tool function"
run_test test_missing_recommended_tool_is_non_fatal "Missing recommended tool does not fail post-create"
run_test test_drift_clean_when_image_matches "Drift check: matching image is clean"
run_test test_drift_warns_on_mismatch "Drift check: mismatch warns and names the key"
run_test test_drift_parses_single_quoted_values "Drift check: single-quoted compose values are parsed"
run_test test_drift_ignores_keys_absent_from_conf "Drift check: keys absent from conf are ignored"
run_test test_drift_skips_when_conf_missing "Drift check: missing conf is skipped"
run_test test_drift_skips_when_compose_missing "Drift check: missing compose file is skipped"
run_test test_drift_does_not_fail_script "Drift check: post-create still exits 0"
run_test test_drift_parses_real_compose "Drift check: parses the real docker-compose.yml"
run_test test_devcontainer_json_wires_hooks "devcontainer.json wires post-create/post-start"
run_test test_old_scripts_removed "Old setup-dev-environment.sh and rebuild.sh are gone"
run_test test_script_checks_shellcheck "Setup script checks for shellcheck"
run_test test_script_checks_docker "Setup script checks for docker"
run_test test_script_checks_lefthook "Setup script checks for lefthook"
run_test test_script_checks_git_config "Setup script checks git user config"
run_test test_no_githooks_directory "No .githooks directory (lefthook uses .git/hooks)"
run_test test_no_precommit_config "No .pre-commit-config.yaml (fully migrated)"

# Generate test report
generate_report
