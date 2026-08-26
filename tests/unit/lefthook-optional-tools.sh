#!/usr/bin/env bash
# Unit tests for the lefthook optional-tool skip policy.
#
# Background (issue #831): every hook that invokes a tool the container may not
# ship must carry a `skip:` guard, so a machine without that tool sees the hook
# SKIPPED rather than FAILED. `docker-compose-validate` was the lone outlier —
# it ran `docker compose` unconditionally and exited 1. Because lefthook
# reports only an aggregate `exit status 1` for a stage, the visible output was
# a sibling hook's, so the failure was routinely misread as "the tests failed".
# The cheapest escape from that is LEFTHOOK=0, which bypasses every OTHER gate
# too — unit tests, gitleaks, osv-scanner. A broken optional-tool gate trains
# people to skip the gates that matter, which is why this is worth a test and
# not just a fix.
#
# Verified against the installed lefthook (2.1.11): a skip-by-condition prints
# "<name> (skip) by condition" and is omitted from the run summary, which is
# what makes a skip visibly distinct from a failure.
#
# These assertions are structural — they read lefthook.yml with yq rather than
# executing hooks, so they hold on any host regardless of which tools it has.

set -euo pipefail

# Source test framework
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "lefthook optional-tool skip policy (#831)"

LEFTHOOK="$PROJECT_ROOT/lefthook.yml"

# Required for these tests; bail with a clear message rather than producing
# confusing failures if absent. Mirrors tests/unit/conform-scopes.sh.
if ! command -v yq >/dev/null 2>&1; then
    echo "SKIP: yq not available — install yq to run lefthook-optional-tools tests"
    generate_report
    exit 0
fi

# Tools that are NOT guaranteed present. Each entry is
#   <tool>|<extended regex matching its invocation in a run: body>
# The invocation regex is not always the tool name: cargo-deny is invoked as
# `cargo deny`. Word boundaries are hand-rolled with [^-[:alnum:]_] so that
# e.g. `hadolint-config` would not count as a `hadolint` invocation.
OPTIONAL_TOOLS=(
    "docker|(^|[^-[:alnum:]_])docker([^-[:alnum:]_]|$)"
    "hadolint|(^|[^-[:alnum:]_])hadolint([^-[:alnum:]_]|$)"
    "actionlint|(^|[^-[:alnum:]_])actionlint([^-[:alnum:]_]|$)"
    "gitleaks|(^|[^-[:alnum:]_])gitleaks([^-[:alnum:]_]|$)"
    "vale|(^|[^-[:alnum:]_])vale([^-[:alnum:]_]|$)"
    "osv-scanner|(^|[^-[:alnum:]_])osv-scanner([^-[:alnum:]_]|$)"
    "conform|(^|[^-[:alnum:]_])conform([^-[:alnum:]_]|$)"
    "cargo-deny|(^|[^-[:alnum:]_])cargo[[:space:]]+deny([^-[:alnum:]_]|$)"
)

# Emit "<hook-name>|<base64 of run: body>" for every command in every stage.
# The body is base64'd because run: bodies are multi-line shell containing
# pipes, quotes and newlines — anything less would mangle them.
lh_commands() {
    yq -r '[.. | select(has("commands")) | .commands | to_entries] | flatten
           | .[] | .key + "|" + ((.value.run // "") | @base64)' "$LEFTHOOK"
}

# The full skip: block of one hook, as JSON ("null" when absent).
#
# The hook name travels through the environment and is read with env(), not
# interpolated into the expression: mikefarah/yq (v4, the yq this repo uses —
# see tests/unit/conform-scopes.sh) has no --arg, and splicing the name into
# the query string would break on any name yq reads as an expression.
lh_skip_json() {
    local hook="$1"
    LH_HOOK="$hook" yq -r \
        '[.. | select(has("commands")) | .commands | to_entries] | flatten
         | map(select(.key == env(LH_HOOK))) | .[0].value.skip | tojson' "$LEFTHOOK"
}

# The run: body of one hook, decoded.
lh_run_body() {
    local hook="$1" line b64
    while IFS='|' read -r line b64; do
        if [ "$line" = "$hook" ]; then
            /usr/bin/printf '%s' "$b64" | /usr/bin/base64 -d
            return 0
        fi
    done < <(lh_commands)
    return 1
}

test_lefthook_yaml_parseable() {
    local out
    out=$(yq -r '.' "$LEFTHOOK" 2>&1) || {
        tf_fail_assertion "lefthook.yml must be valid YAML" "$out"
        return
    }
    assert_not_empty "$out" "lefthook.yml must parse to a non-empty document"
}

# The policy itself: any hook invoking an optional tool must guard on it.
# This is what stops a future hook re-introducing the #831 outlier.
test_every_optional_tool_hook_has_a_skip_guard() {
    local unguarded=""
    local entry tool pattern
    local name b64 body skip

    for entry in "${OPTIONAL_TOOLS[@]}"; do
        tool="${entry%%|*}"
        pattern="${entry#*|}"

        while IFS='|' read -r name b64; do
            [ -n "$name" ] || continue
            body=$(/usr/bin/printf '%s' "$b64" | /usr/bin/base64 -d 2>/dev/null || true)
            [ -n "$body" ] || continue

            # Strip comment lines before matching: several hooks NAME another
            # tool only in prose (osv-scanner's comment cites
            # docker-compose-validate), which is not an invocation.
            body=$(/usr/bin/printf '%s\n' "$body" | /usr/bin/grep -v '^[[:space:]]*#' || true)
            /usr/bin/printf '%s' "$body" | /usr/bin/grep -qE "$pattern" || continue

            skip=$(lh_skip_json "$name")
            case "$skip" in
                null | "") unguarded="$unguarded $name(needs:$tool)" ;;
            esac
        done < <(lh_commands)
    done

    assert_equals "" "$unguarded" \
        "hooks invoking an optional tool must have a skip: guard (#831)"
}

# The specific regression, asserted by name so it cannot be lost in the
# general sweep above if that sweep is ever narrowed.
test_docker_compose_validate_has_a_skip_guard() {
    local skip
    skip=$(lh_skip_json "docker-compose-validate")

    assert_not_equals "null" "$skip" \
        "docker-compose-validate must skip when docker is unavailable (#831)"
    assert_contains "$skip" "docker" \
        "its skip guard must probe docker"
}

# AC3: probe `docker compose`, not bare `docker`. The compose plugin ships
# separately from the CLI, so a `command -v docker` guard would pass on a
# docker-without-plugin host and then fail on every file.
test_docker_compose_validate_probes_the_compose_plugin() {
    local skip
    skip=$(lh_skip_json "docker-compose-validate")

    assert_contains "$skip" "docker compose" \
        "the guard must probe 'docker compose', not just the docker CLI (#831 AC3)"
    assert_not_contains "$skip" "command -v docker >" \
        "a bare 'command -v docker' guard misses a missing compose plugin"
}

# AC2: the `[ -f "$f" ] && cmd || exit 1` precedence bug. When $f is not a
# regular file the && short-circuits and control falls into `|| exit 1`, so a
# non-file match exits as loudly as a genuine compose-config error.
test_docker_compose_validate_has_no_precedence_bug() {
    local body stripped
    if ! body=$(lh_run_body "docker-compose-validate"); then
        tf_fail_assertion "docker-compose-validate must exist" "hook not found"
        return
    fi

    # Drop comments — this hook's own comment quotes the buggy form to explain
    # why it is wrong, and that must not read as the bug itself.
    stripped=$(/usr/bin/printf '%s\n' "$body" | /usr/bin/grep -v '^[[:space:]]*#' || true)

    local hits
    hits=$(/usr/bin/printf '%s\n' "$stripped" | /usr/bin/grep -nE '\][[:space:]]*&&.*\|\|[[:space:]]*exit' || true)

    assert_equals "" "$hits" \
        "test-and-run-or-exit conflates a non-file match with a real failure (#831 AC2)"

    # And the correct form is present.
    assert_contains "$stripped" "|| continue" \
        "a non-regular-file match must continue, not exit"
}

# The guard must be a `skip:` block, not an early `exit 0` inside run:. Only a
# skip: is reported by lefthook as "(skip) by condition"; an in-run exit 0 is
# indistinguishable from the hook having genuinely passed, which is the
# silent-success half of AC5.
test_guard_is_a_skip_block_not_an_inline_exit() {
    local body stripped
    if ! body=$(lh_run_body "docker-compose-validate"); then
        tf_fail_assertion "docker-compose-validate must exist" "hook not found"
        return
    fi

    stripped=$(/usr/bin/printf '%s\n' "$body" | /usr/bin/grep -v '^[[:space:]]*#' || true)

    local hits
    hits=$(/usr/bin/printf '%s\n' "$stripped" |
        /usr/bin/grep -nE 'command -v docker.*exit 0|docker compose version.*exit 0' || true)

    assert_equals "" "$hits" \
        "guard with skip:, not an inline exit 0 — the latter reports as a pass (#831 AC5)"
}

# AC6: a compose service that bind-mounts the Docker socket must also build
# with INCLUDE_DOCKER=true. Mounting the socket without it installs no docker
# CLI and creates no `docker` group, so the socket is present but unusable —
# the host clearly INTENDS Docker access and the image silently withholds it.
# That is the environment #831 was reported from.
test_socket_mounting_composes_enable_the_docker_feature() {
    local mismatched=""
    local f

    while IFS= read -r f; do
        [ -f "$f" ] || continue
        /usr/bin/grep -q 'docker\.sock' "$f" || continue
        # Comment lines mentioning the socket in prose are not mounts, but a
        # false positive here only costs an INCLUDE_DOCKER line, so match
        # broadly and let the assertion message explain.
        /usr/bin/grep -qE 'INCLUDE_DOCKER' "$f" || mismatched="$mismatched $f"
    done < <(git -C "$PROJECT_ROOT" ls-files "*compose*.yml" "*compose*.yaml")

    assert_equals "" "$mismatched" \
        "compose services mounting docker.sock must set INCLUDE_DOCKER (#831 AC6)"
}

run_test test_lefthook_yaml_parseable "lefthook.yml is valid YAML"
run_test test_every_optional_tool_hook_has_a_skip_guard "every optional-tool hook has a skip guard"
run_test test_docker_compose_validate_has_a_skip_guard "docker-compose-validate has a skip guard"
run_test test_docker_compose_validate_probes_the_compose_plugin "docker-compose-validate probes 'docker compose'"
run_test test_docker_compose_validate_has_no_precedence_bug "docker-compose-validate has no && / || exit precedence bug"
run_test test_guard_is_a_skip_block_not_an_inline_exit "the guard is a skip: block, not an inline exit 0"
run_test test_socket_mounting_composes_enable_the_docker_feature "socket-mounting composes enable the docker feature"

generate_report
