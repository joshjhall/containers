#!/bin/bash
# Unit tests for lib/features/lib/dev-tools/persist-feature-flags.sh
#
# Runs persist_feature_flags() for real, with ENABLED_FEATURES_CONF pointed at
# a scratch dir, and asserts on the generated enabled-features.conf content
# rather than grepping the script source (#1308).

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "persist_feature_flags Output Tests"

PERSIST_SRC="$PROJECT_ROOT/lib/features/lib/dev-tools/persist-feature-flags.sh"

# Run persist_feature_flags in a clean environment (env -i), so CLAUDE_* /
# INCLUDE_* vars set on the container running the tests cannot leak into the
# generated file. Extra NAME=value args are exported into that environment.
# log_command is stubbed to drop its description and run the command.
_run_persist() {
    command env -i PATH="$PATH" "$@" /bin/bash -c '
        set -euo pipefail
        log_command() { shift; "$@"; }
        source "$1"
        persist_feature_flags
    ' _ "$PERSIST_SRC"
}

# The conf path every behavioural test writes to. Its parent does not exist
# yet, so each run also exercises the mkdir.
_conf() {
    echo "$TEST_TEMP_DIR/config/enabled-features.conf"
}

# The non-comment, non-blank lines of the generated file.
_key_lines() {
    command grep -vE '^(#|$)' "$(_conf)"
}

test_clean_env_writes_exact_defaults() {
    _run_persist ENABLED_FEATURES_CONF="$(_conf)"

    local expected
    expected='INCLUDE_PYTHON_DEV=false
INCLUDE_NODE_DEV=false
INCLUDE_RUST_DEV=false
INCLUDE_RUBY_DEV=false
INCLUDE_GOLANG_DEV=false
INCLUDE_JAVA_DEV=false
INCLUDE_KOTLIN_DEV=false
INCLUDE_ANDROID_DEV=false
CLAUDE_EXTRA_PLUGINS_DEFAULT=""
CLAUDE_EXTRA_MCPS_DEFAULT=""
CLAUDE_EXTRA_SKILLS_DEFAULT=""
CLAUDE_EXTRA_AGENTS_DEFAULT=""
CLAUDE_PLUGINS_DEFAULT="__UNSET__"
CLAUDE_MCPS_DEFAULT="__UNSET__"
CLAUDE_SKILLS_DEFAULT="__UNSET__"
CLAUDE_LIBRARIAN_PLUGINS_DEFAULT="__UNSET__"
CLAUDE_SKILLS_FILE_DEFAULT=""
CLAUDE_PLUGINS_FILE_DEFAULT=""
CLAUDE_MCPS_FILE_DEFAULT=""
CLAUDE_EXTRA_SKILLS_FILE_DEFAULT=""
CLAUDE_EXTRA_AGENTS_FILE_DEFAULT=""
CLAUDE_EXTRA_PLUGINS_FILE_DEFAULT=""
CLAUDE_EXTRA_MCPS_FILE_DEFAULT=""
INCLUDE_DEV_TOOLS=false
INCLUDE_DOCKER=false
INCLUDE_KUBERNETES=false
INCLUDE_TERRAFORM=false
INCLUDE_AWS=false
INCLUDE_GCLOUD=false
INCLUDE_CLOUDFLARE=false
INCLUDE_HOST_EVENTS=false'

    assert_equals "$expected" "$(_key_lines)" \
        "Clean env writes exactly the default key set"
}

# claude-setup never read CLAUDE_AGENTS (#1051): even when it and its _FILE
# twin are set at build time, they must not be persisted. CLAUDE_EXTRA_AGENTS
# is the live sibling and doubles as the positive control.
test_dead_claude_agents_keys_not_persisted() {
    _run_persist ENABLED_FEATURES_CONF="$(_conf)" \
        CLAUDE_AGENTS=debugger CLAUDE_AGENTS_FILE=/x CLAUDE_EXTRA_AGENTS=foo

    local live dead
    live=$(command grep -xF 'CLAUDE_EXTRA_AGENTS_DEFAULT="foo"' "$(_conf)" || true)
    assert_equals 'CLAUDE_EXTRA_AGENTS_DEFAULT="foo"' "$live" \
        "control: live CLAUDE_EXTRA_AGENTS value persisted"

    dead=$(command grep -E '^CLAUDE_AGENTS(_FILE)?_DEFAULT=' "$(_conf)" || true)
    assert_equals "" "$dead" "No CLAUDE_AGENTS(_FILE)_DEFAULT line written"
}

test_build_values_pass_through() {
    _run_persist ENABLED_FEATURES_CONF="$(_conf)" \
        INCLUDE_PYTHON_DEV=true \
        CLAUDE_PLUGINS="a,b" \
        CLAUDE_SKILLS_FILE=/etc/skills.json

    local got
    got=$(command grep -E '^(INCLUDE_PYTHON_DEV|CLAUDE_PLUGINS_DEFAULT|CLAUDE_SKILLS_FILE_DEFAULT)=' "$(_conf)")
    assert_equals 'INCLUDE_PYTHON_DEV=true
CLAUDE_PLUGINS_DEFAULT="a,b"
CLAUDE_SKILLS_FILE_DEFAULT="/etc/skills.json"' "$got" \
        "Build-time values are written verbatim"
}

# `none` is the only build-time spelling for "no defaults" (#1316): it must reach
# the conf verbatim for the resolver to interpret. An empty build arg is
# indistinguishable from an unset one, so it must map to the sentinel.
test_none_passes_through_empty_maps_to_sentinel() {
    _run_persist ENABLED_FEATURES_CONF="$(_conf)" \
        CLAUDE_PLUGINS=none \
        CLAUDE_MCPS=""

    local got
    got=$(command grep -E '^(CLAUDE_PLUGINS|CLAUDE_MCPS)_DEFAULT=' "$(_conf)")
    assert_equals 'CLAUDE_PLUGINS_DEFAULT="none"
CLAUDE_MCPS_DEFAULT="__UNSET__"' "$got" \
        "none persists verbatim; empty persists as __UNSET__"
}

test_creates_parent_dir_and_sets_mode() {
    _run_persist ENABLED_FEATURES_CONF="$(_conf)"

    local mode
    mode=$(command stat -c '%a' "$(_conf)" 2>/dev/null || echo missing)
    assert_equals "644" "$mode" "Conf file created (parent dir included) with mode 644"
}

# With no override, the first action must target the real build path. The
# stub records the mkdir argv and aborts before anything is written, so the
# test never touches /etc.
test_default_path_unchanged() {
    local out rc=0
    out=$(command env -i PATH="$PATH" /bin/bash -c '
        log_command() { shift; printf "%s\n" "$*"; exit 3; }
        source "$1"
        persist_feature_flags
    ' _ "$PERSIST_SRC") || rc=$?

    assert_equals "3" "$rc" "Stub aborted at the first log_command call"
    assert_equals "mkdir -p /etc/container/config" "$out" \
        "Default conf dir is /etc/container/config"
}

run_test test_clean_env_writes_exact_defaults "Clean env: exact default key set"
run_test test_dead_claude_agents_keys_not_persisted "CLAUDE_AGENTS(_FILE) not persisted"
run_test test_build_values_pass_through "Build-time values written verbatim"
run_test test_none_passes_through_empty_maps_to_sentinel "none persists verbatim; empty maps to __UNSET__"
run_test test_creates_parent_dir_and_sets_mode "Creates parent dir, mode 644"
run_test test_default_path_unchanged "Default path is /etc/container/config"

generate_report
