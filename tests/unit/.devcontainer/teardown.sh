#!/usr/bin/env bash
# Unit tests for .devcontainer/teardown.sh
# Tests argument parsing, the inside-container guards, Compose project-name
# discovery, and the refusal of destructive flags on a guessed project name

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Devcontainer Teardown Tests"

SCRIPT="$PROJECT_ROOT/.devcontainer/teardown.sh"

# Lay out <TEST_TEMP_DIR>/proj/.devcontainer/{teardown.sh,docker-compose.yml}
# (a copy, so the script's DEVCONTAINER_DIR is the sandbox), an empty HOME,
# and a `docker` stub that logs each invocation's args to $TEST_TEMP_DIR/calls.
# The stub answers `ps` with $DOCKER_PS_OUTPUT and everything else with 0.
_make_sandbox() {
    local sb="$TEST_TEMP_DIR"
    command mkdir -p "$sb/proj/.devcontainer" "$sb/home" "$sb/bin"
    command cp "$SCRIPT" "$sb/proj/.devcontainer/teardown.sh"
    command printf 'services: {}\n' >"$sb/proj/.devcontainer/docker-compose.yml"
    : >"$sb/calls"
    command cat >"$sb/bin/docker" <<EOF
#!/bin/sh
echo "\$*" >>"$sb/calls"
if [ "\$1" = ps ]; then
    printf '%s' "\${DOCKER_PS_OUTPUT:-}"
fi
exit 0
EOF
    command chmod +x "$sb/bin/docker"
}

# Run the sandboxed teardown.sh. Extra leading args of the form VAR=value are
# env assignments; the rest are script args. BASH_ENV is unset because the
# container's /etc/bash_env re-prepends system dirs to PATH, which would let a
# real docker shadow the stub. TEARDOWN_DOCKERENV_FILE points at a file that
# does not exist, since this suite itself runs inside a container.
_run_teardown() {
    local -a envs=()
    while [ $# -gt 0 ] && [[ "$1" == *=* ]]; do
        envs+=("$1")
        shift
    done
    command env -u BASH_ENV PATH="$TEST_TEMP_DIR/bin:$PATH" HOME="$TEST_TEMP_DIR/home" \
        TEARDOWN_DOCKERENV_FILE="$TEST_TEMP_DIR/no-dockerenv" "${envs[@]}" \
        bash "$TEST_TEMP_DIR/proj/.devcontainer/teardown.sh" "$@"
}

_compose_prefix() {
    command echo "compose -p $1 -f $TEST_TEMP_DIR/proj/.devcontainer/docker-compose.yml"
}

# --- argument parsing -------------------------------------------------------

test_help_exits_zero() {
    _make_sandbox
    local rc=0 out
    out=$(_run_teardown --help 2>&1) || rc=$?

    assert_equals "0" "$rc" "--help exits 0"
    assert_contains "$out" "Usage:" "--help prints usage"
    assert_not_contains "$(command cat "$TEST_TEMP_DIR/calls")" "down" "--help does not tear anything down"

    rc=0
    out=$(_run_teardown -h 2>&1) || rc=$?
    assert_equals "0" "$rc" "-h exits 0"
    assert_contains "$out" "Usage:" "-h prints usage"
}

test_unknown_option_fails() {
    _make_sandbox
    local rc=0 err
    err=$(_run_teardown --bogus 2>&1 >/dev/null) || rc=$?

    assert_equals "1" "$rc" "Unknown option exits 1"
    assert_contains "$err" "unknown option: --bogus" "Unknown option is named on stderr"
    assert_contains "$err" "Usage:" "Usage is printed on stderr"
}

# --- guards -----------------------------------------------------------------

test_refuses_inside_container_dockerenv() {
    _make_sandbox
    : >"$TEST_TEMP_DIR/dockerenv"
    local rc=0 out
    out=$(_run_teardown TEARDOWN_DOCKERENV_FILE="$TEST_TEMP_DIR/dockerenv" 2>&1) || rc=$?

    assert_equals "1" "$rc" "Exits 1 when /.dockerenv exists"
    assert_contains "$out" "INSIDE the dev container" "Explains it must run on the host"
    assert_equals "" "$(command cat "$TEST_TEMP_DIR/calls")" "docker is never called"
}

test_refuses_inside_container_initialized_marker() {
    _make_sandbox
    : >"$TEST_TEMP_DIR/home/.container-initialized"
    local rc=0 out
    out=$(_run_teardown 2>&1) || rc=$?

    assert_equals "1" "$rc" "Exits 1 when ~/.container-initialized exists"
    assert_contains "$out" "INSIDE the dev container" "Explains it must run on the host"
}

test_fails_without_docker() {
    _make_sandbox
    # A PATH holding only the tools teardown.sh needs before the docker check.
    local tools="$TEST_TEMP_DIR/tools" t rc=0 out
    command mkdir -p "$tools"
    for t in bash dirname; do
        command ln -s "$(command -v "$t")" "$tools/$t"
    done
    out=$(command env -u BASH_ENV PATH="$tools" HOME="$TEST_TEMP_DIR/home" \
        TEARDOWN_DOCKERENV_FILE="$TEST_TEMP_DIR/no-dockerenv" \
        "$tools/bash" "$TEST_TEMP_DIR/proj/.devcontainer/teardown.sh" 2>&1) || rc=$?

    assert_equals "1" "$rc" "Exits 1 when docker is missing"
    assert_contains "$out" "docker not found" "Reports the missing docker"
}

test_fails_without_compose_file() {
    _make_sandbox
    command rm "$TEST_TEMP_DIR/proj/.devcontainer/docker-compose.yml"
    local rc=0 out
    out=$(_run_teardown 2>&1) || rc=$?

    assert_equals "1" "$rc" "Exits 1 when the compose file is missing"
    assert_contains "$out" "compose file not found" "Reports the missing compose file"
}

# --- discovered project name ------------------------------------------------

test_discovered_name_plain_down() {
    _make_sandbox
    local rc=0 out
    out=$(_run_teardown DOCKER_PS_OUTPUT="myproj_devcontainer" 2>&1) || rc=$?

    assert_equals "0" "$rc" "Teardown exits 0"
    assert_contains "$out" "Targeting Compose project: myproj_devcontainer" "Discovered name is reported"
    assert_contains "$(command cat "$TEST_TEMP_DIR/calls")" \
        "label=com.docker.compose.project.working_dir=$TEST_TEMP_DIR/proj/.devcontainer" \
        "Discovery filters on the .devcontainer working_dir label"
    assert_equals "$(_compose_prefix myproj_devcontainer) down" "$(command tail -n 1 "$TEST_TEMP_DIR/calls")" \
        "Runs a plain compose down on the discovered project"
}

test_discovered_name_rmi_and_volumes() {
    _make_sandbox
    _run_teardown DOCKER_PS_OUTPUT="myproj_devcontainer" --rmi >/dev/null 2>&1
    assert_equals "$(_compose_prefix myproj_devcontainer) down --rmi local" "$(command tail -n 1 "$TEST_TEMP_DIR/calls")" \
        "--rmi adds --rmi local"

    _run_teardown DOCKER_PS_OUTPUT="myproj_devcontainer" -v >/dev/null 2>&1
    assert_equals "$(_compose_prefix myproj_devcontainer) down --volumes" "$(command tail -n 1 "$TEST_TEMP_DIR/calls")" \
        "-v adds --volumes"

    _run_teardown DOCKER_PS_OUTPUT="myproj_devcontainer" --rmi --volumes >/dev/null 2>&1
    assert_equals "$(_compose_prefix myproj_devcontainer) down --rmi local --volumes" "$(command tail -n 1 "$TEST_TEMP_DIR/calls")" \
        "--rmi --volumes adds both"
}

# --- fallback (guessed) project name ----------------------------------------

test_fallback_name_plain_down() {
    _make_sandbox
    local rc=0 out
    out=$(_run_teardown 2>&1) || rc=$?

    assert_equals "0" "$rc" "Teardown exits 0 on the fallback name"
    assert_contains "$out" "assuming project name: proj_devcontainer" "Fallback name is <folder>_devcontainer"
    assert_equals "$(_compose_prefix proj_devcontainer) down" "$(command tail -n 1 "$TEST_TEMP_DIR/calls")" \
        "Plain down still runs on the fallback name"
}

# Two clones with the same folder name share the guessed name, so a
# destructive flag could wipe the OTHER clone's image or cache volumes.
test_fallback_name_refuses_destructive_flags() {
    _make_sandbox
    local flag rc out
    for flag in --rmi --volumes -v; do
        rc=0
        out=$(_run_teardown "$flag" 2>&1) || rc=$?

        assert_equals "1" "$rc" "$flag on a guessed name exits 1"
        assert_contains "$out" "refusing --rmi/--volumes on a guessed project name" "$flag refusal is explained"
        assert_not_contains "$(command cat "$TEST_TEMP_DIR/calls")" "down" "$flag refusal runs no compose down"
    done
    assert_contains "$out" "docker compose -p proj_devcontainer" "Refusal prints the explicit command to run"
}

run_test test_help_exits_zero "--help / -h print usage and exit 0"
run_test test_unknown_option_fails "Unknown option exits 1 with usage"
run_test test_refuses_inside_container_dockerenv "Refuses to run when /.dockerenv exists"
run_test test_refuses_inside_container_initialized_marker "Refuses to run when ~/.container-initialized exists"
run_test test_fails_without_docker "Fails when docker is not on PATH"
run_test test_fails_without_compose_file "Fails when the compose file is missing"
run_test test_discovered_name_plain_down "Discovered project name: plain down"
run_test test_discovered_name_rmi_and_volumes "Discovered project name: --rmi / --volumes"
run_test test_fallback_name_plain_down "Fallback project name: plain down"
run_test test_fallback_name_refuses_destructive_flags "Fallback project name: refuses --rmi / --volumes"

# Generate test report
generate_report
