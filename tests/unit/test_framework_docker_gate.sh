#!/usr/bin/env bash
# Regression test for issue #831: the test framework must not gate Docker-free
# suites on Docker.
#
# init_test_framework() used to abort with "ERROR: Docker is not installed or
# not in PATH" whenever `docker` was absent, unless the suite set
# SKIP_DOCKER_CHECK=true. Only 5 of 167 unit suites set that opt-out, so in a
# container built with INCLUDE_DOCKER=false the other ~162 pure-shell suites —
# none of which touch a daemon — refused to run. The pre-push `unit-tests` hook
# then failed for reasons unrelated to the code under test, and because
# lefthook reports only an aggregate `exit status 1`, the failure was routinely
# misread as "the tests failed". The documented escape (LEFTHOOK=0) bypasses
# every other gate too, which is the real cost.
#
# The gate now lives on require_docker(), called by the suites that genuinely
# build or run containers.
#
# The framework is exercised in a CHILD shell (not by calling
# init_test_framework in this process), because init_test_framework() resets
# the suite's pass/fail counters — re-running it mid-suite would corrupt this
# file's own report. Same technique as test_framework_scratch_base.sh (#821).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"
init_test_framework

FRAMEWORK_SH="$SCRIPT_DIR/../framework.sh"

test_suite "test framework does not gate Docker-free suites on Docker (#831)"

# ---------------------------------------------------------------------------
# Build a PATH with no `docker` on it, so these tests assert the no-Docker
# behaviour even on a machine that HAS Docker (CI does, and so does any
# INCLUDE_DOCKER=true container).
#
# Mirror rather than scrub or shim:
#
#   - A fake `docker` placed on a prepended dir does not work — `command -v`
#     would find it, and that probe is exactly what is under test.
#   - Dropping whole PATH components that contain a `docker` does not work
#     either: on a GitHub runner (and most distros) `docker` lives in
#     /usr/bin alongside coreutils, so removing that component takes `date`,
#     `mkdir` and friends with it and the child dies with 127 before it can
#     assert anything.
#
# So mirror every executable on PATH into one scratch dir as symlinks, skipping
# only `docker`, and point the child at that single dir. The environment is
# otherwise identical to the parent's — just one binary short.
# ---------------------------------------------------------------------------
make_docker_free_bin() {
    local mirror="$TEST_SCRATCH_BASE/docker-free-bin"
    /usr/bin/mkdir -p "$mirror"

    local dir entry name
    local IFS=:
    for dir in $PATH; do
        [ -n "$dir" ] || continue
        [ -d "$dir" ] || continue
        # Unset IFS inside the glob loop: the ':' split above would otherwise
        # apply to the paths this expands.
        local OLD_IFS="$IFS"
        IFS=' '
        for entry in "$dir"/*; do
            [ -f "$entry" ] || continue
            [ -x "$entry" ] || continue
            name=$(/usr/bin/basename "$entry")
            [ "$name" = "docker" ] && continue
            # First PATH component wins, matching real PATH resolution order.
            [ -e "$mirror/$name" ] && continue
            /usr/bin/ln -s "$entry" "$mirror/$name" 2>/dev/null || true
        done
        IFS="$OLD_IFS"
    done

    /usr/bin/printf '%s' "$mirror"
}

DOCKER_FREE_PATH="$(make_docker_free_bin)"

# Run $body in a child shell with the framework sourced. The caller chooses the
# PATH and whether SKIP_DOCKER_CHECK is exported. Paths travel through the
# environment (not interpolated into -c) so a repo path containing an
# apostrophe cannot break the quoting.
run_in_child() {
    local child_path="$1" skip_flag="$2" body="$3"
    /usr/bin/env -i \
        PATH="$child_path" \
        HOME="${HOME:-/tmp}" \
        TERM="dumb" \
        SKIP_DOCKER_CHECK="$skip_flag" \
        FRAMEWORK_SH="$FRAMEWORK_SH" \
        /bin/bash -c 'source "$FRAMEWORK_SH" >/dev/null 2>&1; '"$body"
}

# Sanity check: the mirrored PATH really has no docker, or every assertion
# below would pass vacuously on a Docker-free host and prove nothing on a
# Docker-equipped one. It must ALSO still resolve coreutils — an earlier version
# of this helper dropped whole PATH components, which on a GitHub runner took
# /usr/bin (and therefore `date`/`mkdir`) with it and failed every test with 127.
test_mirrored_path_has_no_docker_but_keeps_coreutils() {
    local out
    out=$(run_in_child "$DOCKER_FREE_PATH" "" '
        command -v docker >/dev/null 2>&1 \
            && /usr/bin/echo "docker=present" \
            || /usr/bin/echo "docker=absent"
    ' 2>&1 || true)

    assert_contains "$out" "docker=absent" \
        "the mirrored PATH must not resolve docker, or these tests prove nothing"

    # And the tools the child needs are still reachable. Asserted explicitly
    # because losing them is a silent 127 that looks like a real failure.
    local tools
    tools=$(run_in_child "$DOCKER_FREE_PATH" "" '
        for t in bash date mkdir grep; do
            command -v "$t" >/dev/null 2>&1 || /usr/bin/echo "missing=$t"
        done
        /usr/bin/echo "checked=yes"
    ' 2>&1 || true)

    assert_contains "$tools" "checked=yes" "the mirrored PATH must run a child shell"
    assert_not_contains "$tools" "missing=" \
        "the mirrored PATH must keep coreutils — dropping them yields a bogus 127"
}

# THE regression: no docker, no opt-out, and init must still succeed.
test_init_succeeds_without_docker_and_without_optout() {
    local out status
    out=$(run_in_child "$DOCKER_FREE_PATH" "" '
        init_test_framework >/dev/null 2>&1 || exit 1
        /usr/bin/echo "init=ok"
    ' 2>&1) && status=0 || status=$?

    assert_equals "0" "$status" \
        "init_test_framework must succeed with no docker and no SKIP_DOCKER_CHECK (#831)"
    assert_contains "$out" "init=ok" "init_test_framework should complete"
}

# The old failure mode, asserted by its message so a revert is caught even if
# it exits 0 for some other reason.
test_init_does_not_emit_the_docker_error() {
    local out
    out=$(run_in_child "$DOCKER_FREE_PATH" "" 'init_test_framework 2>&1' 2>&1 || true)

    assert_not_contains "$out" "Docker is not installed" \
        "init_test_framework must not report a missing Docker binary"
    assert_not_contains "$out" "Docker daemon is not running" \
        "init_test_framework must not probe the Docker daemon"
}

# Back-compat: 7 unit suites and .github/workflows/ci.yml export this. It is
# now a no-op, but exporting it must not break anything.
test_skip_docker_check_is_still_accepted() {
    local out status
    out=$(run_in_child "$DOCKER_FREE_PATH" "true" '
        init_test_framework >/dev/null 2>&1 || exit 1
        /usr/bin/echo "init=ok"
    ' 2>&1) && status=0 || status=$?

    assert_equals "0" "$status" \
        "SKIP_DOCKER_CHECK=true must remain accepted (7 suites + ci.yml export it)"
    assert_contains "$out" "init=ok" "init_test_framework should complete"
}

# The gate did not vanish — it moved.
test_require_docker_fails_without_docker() {
    local out status
    out=$(run_in_child "$DOCKER_FREE_PATH" "" 'require_docker 2>&1' 2>&1) && status=0 || status=$?

    assert_not_equals "0" "$status" \
        "require_docker must fail when docker is absent"
    assert_contains "$out" "Docker is not installed" \
        "require_docker must say why it failed"
}

# SKIP_DOCKER_CHECK is an init-time no-op and must NOT weaken require_docker —
# otherwise the 7 suites that export it could silently skip a real gate.
test_require_docker_ignores_skip_docker_check() {
    local status
    run_in_child "$DOCKER_FREE_PATH" "true" 'require_docker >/dev/null 2>&1' &&
        status=0 || status=$?

    assert_not_equals "0" "$status" \
        "SKIP_DOCKER_CHECK must not disable require_docker"
}

# Every integration suite that builds or runs containers must self-gate, so a
# direct run_test.sh invocation (which bypasses the runner-level checks) still
# fails clearly rather than confusingly.
test_integration_suites_call_require_docker() {
    local missing=""
    local suite
    for suite in "$PROJECT_ROOT"/tests/integration/builds/test_*.sh; do
        [ -f "$suite" ] || continue
        /usr/bin/grep -q '^require_docker$' "$suite" ||
            missing="$missing $(basename "$suite")"
    done

    assert_equals "" "$missing" \
        "integration build suites must call require_docker after init_test_framework"
}

# The inverse guard: a unit suite calling require_docker would re-create #831
# for that suite.
test_no_unit_suite_calls_require_docker() {
    local offenders
    offenders=$(/usr/bin/grep -rl '^require_docker$' "$PROJECT_ROOT/tests/unit" 2>/dev/null || true)

    assert_equals "" "$offenders" \
        "unit suites must not gate on Docker — that is the #831 regression"
}

run_test test_mirrored_path_has_no_docker_but_keeps_coreutils "mirrored PATH drops docker but keeps coreutils"
run_test test_init_succeeds_without_docker_and_without_optout "init_test_framework succeeds with no docker and no opt-out"
run_test test_init_does_not_emit_the_docker_error "init_test_framework does not probe Docker at all"
run_test test_skip_docker_check_is_still_accepted "SKIP_DOCKER_CHECK=true remains accepted as a no-op"
run_test test_require_docker_fails_without_docker "require_docker fails clearly when docker is absent"
run_test test_require_docker_ignores_skip_docker_check "require_docker ignores SKIP_DOCKER_CHECK"
run_test test_integration_suites_call_require_docker "integration build suites self-gate on Docker"
run_test test_no_unit_suite_calls_require_docker "no unit suite gates on Docker"

generate_report
