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

# Build a throwaway project root: a copy of post-create.sh plus the files it
# reads (colors.sh, docker-compose.yml). post-create.sh derives PROJECT_ROOT
# from BASH_SOURCE and cd's there, so running the COPY confines every write
# (.gitignore append, lefthook install) to the sandbox, never the live tree.
# Pass --no-git to leave it outside any git work tree. GIT_CEILING_DIRECTORIES
# (set by _run_post_create) stops git from discovering an enclosing repo.
_make_sandbox() {
    local dir=$1 mode=${2:-}
    command mkdir -p "$dir/.devcontainer" "$dir/lib/shared"
    command cp "$PROJECT_ROOT/.devcontainer/post-create.sh" "$PROJECT_ROOT/.devcontainer/docker-compose.yml" \
        "$dir/.devcontainer/"
    command cp "$PROJECT_ROOT/lib/shared/colors.sh" "$dir/lib/shared/"
    if [ "$mode" != "--no-git" ]; then
        _hermetic_git -C "$dir" init -q
    fi
}

# Environment that isolates git from the caller's global/system config, so a
# developer whose global ignore (core.excludesFile, ~/.config/git/ignore)
# lists .env cannot make the sandbox report ".env is ignored". Set as an array
# of env assignments for `command env`.
_hermetic_git_env() {
    command mkdir -p "$TEST_TEMP_DIR/home"
    HERMETIC_GIT_ENV=(HOME="$TEST_TEMP_DIR/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1)
}

_hermetic_git() {
    _hermetic_git_env
    command env -u XDG_CONFIG_HOME "${HERMETIC_GIT_ENV[@]}" git "$@"
}

# Run the sandboxed post-create.sh with `lefthook` stubbed: the stub logs its
# args to <sandbox>/lefthook.calls and exits $LEFTHOOK_STUB_RC (default 0).
# Extra args are env assignments. Git runs hermetically (_hermetic_git_env),
# so the step-5 identity check reports "not configured" — that is expected.
# BASH_ENV is unset because the container's /etc/bash_env re-prepends system
# dirs to PATH, which would let the real lefthook shadow the stub.
_run_post_create() {
    local sandbox=$1
    shift
    local stub="$TEST_TEMP_DIR/stub-bin"
    command mkdir -p "$stub"
    command printf '#!/bin/sh\necho "$*" >>"$LEFTHOOK_CALLS"\nexit "${LEFTHOOK_STUB_RC:-0}"\n' >"$stub/lefthook"
    command chmod +x "$stub/lefthook"
    _hermetic_git_env
    command env -u BASH_ENV -u XDG_CONFIG_HOME "${HERMETIC_GIT_ENV[@]}" \
        PATH="$stub:$PATH" LEFTHOOK_CALLS="$sandbox/lefthook.calls" \
        GIT_CEILING_DIRECTORIES="$(command dirname "$sandbox")" \
        ENABLED_FEATURES_CONF="$sandbox/no-such-features.conf" "$@" \
        bash "$sandbox/.devcontainer/post-create.sh"
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

# Test: a full run exits 0 and reports every step.
#
# post-create.sh runs under `set -euo pipefail` as the postCreateCommand, and
# VS Code skips postStartCommand when postCreateCommand fails — so any
# advisory check that returns non-zero would skip setup-git/setup-gh and leave
# the container without git identity + SSH auth keys. See
# docs/troubleshooting/zed-devcontainer.md (chain-abort gotcha).
test_full_run_exits_zero_and_reports_steps() {
    local sb="$TEST_TEMP_DIR/sb" rc=0 out
    _make_sandbox "$sb"

    out=$(_run_post_create "$sb" 2>&1) || rc=$?

    assert_equals "0" "$rc" "post-create.sh exits 0"
    assert_equals "install" "$(command cat "$sb/lefthook.calls")" "lefthook is invoked as 'lefthook install'"
    assert_contains "$out" "lefthook hooks installed" "Successful lefthook install is reported"
    local tool
    for tool in shellcheck docker gh jq git-cliff lefthook biome; do
        assert_contains "$out" " $tool " "Recommended tool '$tool' is checked"
    done
    assert_contains "$out" "[5/5] Checking git configuration" "Git configuration step runs"
    assert_contains "$out" "Setup Complete" "Script runs to the summary"
}

# Test: a MISSING recommended tool is reported but does not fail check_tool.
test_missing_recommended_tool_is_non_fatal() {
    local out
    out=$(
        # shellcheck source=/dev/null
        source "$PROJECT_ROOT/.devcontainer/post-create.sh"
        set +e
        check_tool "no-such-tool-1072" "install hint here"
        echo "rc=$?"
    )

    assert_contains "$out" "no-such-tool-1072 not found - install hint here" "Missing tool is reported with its hint"
    assert_contains "$out" "rc=0" "check_tool returns 0 for a missing tool"
}

test_lefthook_install_failure_is_non_fatal() {
    local sb="$TEST_TEMP_DIR/sb" rc=0 out
    _make_sandbox "$sb"

    out=$(_run_post_create "$sb" LEFTHOOK_STUB_RC=1 2>&1) || rc=$?

    assert_equals "0" "$rc" "post-create.sh exits 0 when lefthook install fails"
    assert_equals "install" "$(command cat "$sb/lefthook.calls")" "lefthook install was attempted"
    assert_contains "$out" "Failed to install lefthook hooks" "lefthook failure is reported"
}

# --- .env checks --------------------------------------------------------------

test_env_with_real_credentials_warns() {
    local sb="$TEST_TEMP_DIR/sb" out
    _make_sandbox "$sb"
    # Assembled at runtime so secret scanners never see a token-shaped literal.
    command printf 'GITHUB_TOKEN=%s%s\n' "ghp_" "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" >"$sb/.env"

    out=$(_run_post_create "$sb" 2>&1)

    assert_contains "$out" ".env contains what appear to be real credentials" "Token-shaped .env value is flagged"
    assert_not_contains "$out" "appears sanitized" "Flagged .env is not called sanitized"
}

test_env_sanitized_passes() {
    local sb="$TEST_TEMP_DIR/sb" out
    _make_sandbox "$sb"
    command printf 'GITHUB_TOKEN=changeme\n' >"$sb/.env"

    out=$(_run_post_create "$sb" 2>&1)

    assert_contains "$out" ".env exists and appears sanitized" "Placeholder .env is reported as sanitized"
}

test_env_missing_is_reported() {
    local sb="$TEST_TEMP_DIR/sb" out
    _make_sandbox "$sb"

    out=$(_run_post_create "$sb" 2>&1)

    assert_contains "$out" ".env does not exist" "Missing .env is reported"
}

# --- .gitignore auto-append ---------------------------------------------------

test_gitignore_already_ignores_env() {
    local sb="$TEST_TEMP_DIR/sb" out
    _make_sandbox "$sb"
    command printf '**/.env\n' >"$sb/.gitignore"

    out=$(_run_post_create "$sb" 2>&1)

    assert_contains "$out" ".env is ignored by .gitignore" "Existing ignore pattern is recognized"
    assert_equals "**/.env" "$(command cat "$sb/.gitignore")" ".gitignore is left unchanged"
}

test_gitignore_append_with_trailing_newline() {
    local sb="$TEST_TEMP_DIR/sb" out
    _make_sandbox "$sb"
    command printf 'node_modules/\n' >"$sb/.gitignore"

    out=$(_run_post_create "$sb" 2>&1)

    assert_contains "$out" ".env is NOT ignored" "Missing ignore entry is reported"
    assert_equals "$(command printf 'node_modules/\n.env')" "$(command cat "$sb/.gitignore")" \
        ".env is appended on its own line, no blank line inserted"
}

test_gitignore_append_without_trailing_newline() {
    local sb="$TEST_TEMP_DIR/sb"
    _make_sandbox "$sb"
    command printf 'foo' >"$sb/.gitignore"

    _run_post_create "$sb" >/dev/null 2>&1

    assert_equals "$(command printf 'foo\n.env')" "$(command cat "$sb/.gitignore")" \
        "A newline is inserted before .env (no 'foo.env' merge)"
    local ignored=0
    _hermetic_git -C "$sb" check-ignore -q .env || ignored=$?
    assert_equals "0" "$ignored" ".env is now actually ignored by git"
}

# .gitignore is a DIRECTORY, so the append fails for every uid (root ignores
# file modes, not EISDIR). This also drives the trailing-newline probe down
# its failure path: `[ -s ]` is true for a directory but `tail -c 1` errors,
# which must not abort the script under set -e.
test_gitignore_write_failure_is_non_fatal() {
    local sb="$TEST_TEMP_DIR/sb" rc=0 out
    _make_sandbox "$sb"
    command mkdir "$sb/.gitignore"

    out=$(_run_post_create "$sb" 2>&1) || rc=$?

    assert_equals "0" "$rc" "post-create.sh exits 0 when .gitignore is not writable"
    assert_contains "$out" ".env is NOT ignored" "Unwritable .gitignore still reports the missing entry"
    assert_contains "$out" "Could not write .gitignore" "Write failure is reported"
    assert_contains "$out" "Setup Complete" "Script continues past the write failure"
}

# Outside a work tree, git check-ignore exits 128; that must not be read as
# "not ignored" and trigger an append.
test_gitignore_skipped_outside_work_tree() {
    local sb="$TEST_TEMP_DIR/sb" rc=0 out
    _make_sandbox "$sb" --no-git

    out=$(_run_post_create "$sb" 2>&1) || rc=$?

    assert_equals "0" "$rc" "post-create.sh exits 0 outside a git work tree"
    assert_contains "$out" "Not inside a git work tree" "Skip note is printed"
    assert_not_contains "$out" "NOT ignored" "No false 'not ignored' report"
    assert_file_not_exists "$sb/.gitignore" "No .gitignore is created"
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

test_drift_warns_when_nothing_compared() {
    local dir out
    dir=$(_drift_fixture_dir)
    command printf '%s\n' INCLUDE_KUBERNETES=false >"$dir/features.conf"

    out=$(_run_drift "$dir/compose.yml" "$dir/features.conf")

    assert_contains "$out" "rc=0" "Zero overlap returns 0"
    assert_contains "$out" "drift not verified" "Zero overlap warns instead of claiming a match"
    assert_not_contains "$out" "Image matches" "Zero overlap does not print the success line"
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

    _make_sandbox "$TEST_TEMP_DIR/sb"
    out=$(_run_post_create "$TEST_TEMP_DIR/sb" ENABLED_FEATURES_CONF="$dir/features.conf" 2>&1) || rc=$?

    assert_equals "0" "$rc" "post-create.sh exits 0 even when the image drifts"
    assert_contains "$out" "IMAGE IS STALE" "post-create.sh surfaces the drift warning"
}

test_drift_parses_inline_comment() {
    local dir="$TEST_TEMP_DIR/inline" out
    command mkdir -p "$dir"
    command printf '        INCLUDE_GOLANG_DEV: "true"  # Go toolchain\n' >"$dir/compose.yml"
    command printf '%s\n' INCLUDE_GOLANG_DEV=false >"$dir/features.conf"

    out=$(_run_drift "$dir/compose.yml" "$dir/features.conf")

    assert_contains "$out" "INCLUDE_GOLANG_DEV: compose=true image=false" "Value before an inline # comment is parsed"
}

# The conf lookup takes the LAST matching line (`tail -n 1`).
test_drift_duplicate_conf_key_last_wins() {
    local dir out
    dir=$(_drift_fixture_dir)
    command printf '%s\n' INCLUDE_RUST_DEV=false INCLUDE_RUST_DEV=true >"$dir/features.conf"

    out=$(_run_drift "$dir/compose.yml" "$dir/features.conf")

    assert_contains "$out" "rc=0" "Later duplicate conf key overrides the earlier one"
    assert_not_contains "$out" "STALE" "No drift reported from the overridden conf line"
}

# Every compose occurrence is compared, so a duplicated key that disagrees
# with the image is reported for the disagreeing occurrence only.
test_drift_duplicate_compose_key_each_compared() {
    local dir="$TEST_TEMP_DIR/dupcompose" out
    command mkdir -p "$dir"
    command printf '%s\n' '  INCLUDE_RUST_DEV: "true"' '  INCLUDE_RUST_DEV: "false"' >"$dir/compose.yml"
    command printf '%s\n' INCLUDE_RUST_DEV=true >"$dir/features.conf"

    out=$(_run_drift "$dir/compose.yml" "$dir/features.conf")

    assert_contains "$out" "rc=1" "Disagreeing duplicate compose key is drift"
    assert_contains "$out" "INCLUDE_RUST_DEV: compose=false image=true" "The disagreeing occurrence is named"
    assert_not_contains "$out" "compose=true image=true" "The agreeing occurrence is not listed"
}

# Test: the real compose file's INCLUDE_* args are parseable by the check.
# The expected value is read from the file, so flipping the flag in compose
# does not break this test.
test_drift_parses_real_compose() {
    local dir out compose want other
    compose="$PROJECT_ROOT/.devcontainer/docker-compose.yml"
    want=$(command sed -n -E 's/^[[:space:]]*INCLUDE_RUST_DEV:[[:space:]]*["'\'']?(true|false).*/\1/p' "$compose" | command tail -n 1)
    assert_not_empty "$want" "Real compose declares INCLUDE_RUST_DEV"
    if [ "$want" = true ]; then other=false; else other=true; fi
    dir="$TEST_TEMP_DIR/real"
    command mkdir -p "$dir"
    # Claim the opposite of whatever compose says → must drift.
    command printf '%s\n' "INCLUDE_RUST_DEV=$other" >"$dir/features.conf"

    out=$(_run_drift "$compose" "$dir/features.conf")

    assert_contains "$out" "INCLUDE_RUST_DEV: compose=$want image=$other" "Real compose INCLUDE_RUST_DEV is detected"
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
run_test test_full_run_exits_zero_and_reports_steps "Full sandboxed run exits 0 and reports every step"
run_test test_missing_recommended_tool_is_non_fatal "Missing recommended tool does not fail check_tool"
run_test test_lefthook_install_failure_is_non_fatal "lefthook install failure does not fail post-create"
run_test test_env_with_real_credentials_warns ".env with real-looking credentials warns"
run_test test_env_sanitized_passes "Sanitized .env passes"
run_test test_env_missing_is_reported "Missing .env is reported"
run_test test_gitignore_already_ignores_env ".gitignore already ignoring .env is left alone"
run_test test_gitignore_append_with_trailing_newline ".env appended to .gitignore with trailing newline"
run_test test_gitignore_append_without_trailing_newline ".env appended to .gitignore without trailing newline"
run_test test_gitignore_write_failure_is_non_fatal "Unwritable .gitignore does not fail post-create"
run_test test_gitignore_skipped_outside_work_tree ".gitignore check skipped outside a git work tree"
run_test test_drift_clean_when_image_matches "Drift check: matching image is clean"
run_test test_drift_warns_on_mismatch "Drift check: mismatch warns and names the key"
run_test test_drift_parses_single_quoted_values "Drift check: single-quoted compose values are parsed"
run_test test_drift_ignores_keys_absent_from_conf "Drift check: keys absent from conf are ignored"
run_test test_drift_warns_when_nothing_compared "Drift check: zero comparable flags warns"
run_test test_drift_skips_when_conf_missing "Drift check: missing conf is skipped"
run_test test_drift_skips_when_compose_missing "Drift check: missing compose file is skipped"
run_test test_drift_does_not_fail_script "Drift check: post-create still exits 0"
run_test test_drift_parses_inline_comment "Drift check: inline # comment after a value is parsed"
run_test test_drift_duplicate_conf_key_last_wins "Drift check: duplicate conf key, last wins"
run_test test_drift_duplicate_compose_key_each_compared "Drift check: duplicate compose key, each compared"
run_test test_drift_parses_real_compose "Drift check: parses the real docker-compose.yml"
run_test test_devcontainer_json_wires_hooks "devcontainer.json wires post-create/post-start"
run_test test_old_scripts_removed "Old setup-dev-environment.sh and rebuild.sh are gone"
run_test test_no_githooks_directory "No .githooks directory (lefthook uses .git/hooks)"
run_test test_no_precommit_config "No .pre-commit-config.yaml (fully migrated)"

# Generate test report
generate_report
