#!/usr/bin/env bash
# Unit tests for the lefthook cargo rebuild hint (issue #1060).
#
# Background: a golem run hit an image built with INCLUDE_RUST_DEV=false while
# .devcontainer/docker-compose.yml asked for Rust. Every push failed the
# cargo-test hook with a bare "cargo: command not found", and one golem
# hand-installed rustup to get unblocked — masking the stale image. The fix is
# a rebuild, so cargo-lint/cargo-test now say so when cargo is missing.
#
# These hooks deliberately do NOT follow the #831 optional-tool policy (see
# tests/unit/lefthook-optional-tools.sh): Rust is required here, so a missing
# cargo must FAIL with the hint rather than skip and let Rust through
# unlinted/untested.
#
# The run: bodies are extracted with yq and executed under an empty PATH, so
# the guard is exercised for real on any host, whether or not it has cargo.

set -euo pipefail

# Source test framework
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "lefthook cargo rebuild hint (#1060)"

LEFTHOOK="$PROJECT_ROOT/lefthook.yml"

# Mirrors tests/unit/lefthook-optional-tools.sh.
if ! command -v yq >/dev/null 2>&1; then
    echo "SKIP: yq not available — install yq to run lefthook-cargo-hint tests"
    generate_report
    exit 0
fi

# A single hook's field (run / skip) as raw text; "null" when absent. The hook
# name travels through env() — mikefarah/yq v4 has no --arg.
lh_field() {
    local hook="$1" field="$2"
    LH_HOOK="$hook" LH_FIELD="$field" yq -r \
        '[.. | select(has("commands")) | .commands | to_entries] | flatten
         | map(select(.key == env(LH_HOOK))) | .[0].value[env(LH_FIELD)]' "$LEFTHOOK"
}

# Run one hook's body with no cargo reachable; assert it fails with the hint.
assert_hook_fails_with_rebuild_hint() {
    local hook="$1" body stderr rc=0
    body=$(lh_field "$hook" run)
    if [ -z "$body" ] || [ "$body" = "null" ]; then
        tf_fail_assertion "$hook must exist in lefthook.yml" "hook not found"
        return
    fi

    # -u BASH_ENV: a container BASH_ENV re-exports PATH and would find cargo.
    stderr=$(env -u BASH_ENV PATH=/nonexistent /bin/bash -c "$body" 2>&1 >/dev/null) || rc=$?

    assert_equals "1" "$rc" "$hook must fail (not skip or pass) when cargo is missing"
    assert_contains "$stderr" "Rebuild the devcontainer" \
        "$hook must tell the user to rebuild rather than install rustup"
}

test_cargo_lint_hint() {
    assert_hook_fails_with_rebuild_hint "cargo-lint"
}

test_cargo_test_hint() {
    assert_hook_fails_with_rebuild_hint "cargo-test"
}

# A skip: guard would turn a stale image into a silent pass — the opposite of
# what #1060 wants. Pin its absence so a future #831-style sweep can't add one.
test_cargo_hooks_have_no_skip_guard() {
    assert_equals "null" "$(lh_field cargo-lint skip)" \
        "cargo-lint must not skip on missing cargo (#1060)"
    assert_equals "null" "$(lh_field cargo-test skip)" \
        "cargo-test must not skip on missing cargo (#1060)"
}

run_test test_cargo_lint_hint "cargo-lint fails with a rebuild hint when cargo is missing"
run_test test_cargo_test_hint "cargo-test fails with a rebuild hint when cargo is missing"
run_test test_cargo_hooks_have_no_skip_guard "cargo hooks fail rather than skip"

generate_report
