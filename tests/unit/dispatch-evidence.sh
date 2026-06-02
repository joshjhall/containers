#!/usr/bin/env bash
# Unit tests for bin/dispatch-evidence.sh — the auto-patch post-merge step that
# triggers luggage evidence runs for bumped, luggage-managed tools (#506 Phase 2).
#
# These tests drive the script against a throwaway git repo (DISPATCH_PROJECT_ROOT)
# and a fake `gh` injected via the script's `GH` override (an absolute path —
# PATH-shadowing is unreliable here because the shell re-initializes PATH from
# the profile on each bash startup). No network or real dispatch happens. The
# fake `gh`'s behavior is controlled by SIBLING_PRESENT:
#   SIBLING_PRESENT=1  -> `gh api .../contents/...` exits 0 (version present)
#   SIBLING_PRESENT=0  -> `gh api` exits 1 (404 — version absent)
# `gh workflow run` always exits 0 (the script's own stdout reports the dispatch).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "dispatch-evidence.sh tests"

DISPATCH_SCRIPT="$PROJECT_ROOT/bin/dispatch-evidence.sh"

# Build a throwaway repo with a Dockerfile, then change one ARG in a second
# commit. Echoes "<base_sha> <head_sha>". The repo lives at a deterministic
# path ($TEST_TEMP_DIR/repo) so callers don't depend on a variable surviving
# the process-substitution subshell this runs in.
# Args: <arg_to_change> <new_value>   (empty new_value => no second commit)
make_repo() {
    local change_arg="$1" new_value="$2"
    local REPO_DIR="$TEST_TEMP_DIR/repo"
    command mkdir -p "$REPO_DIR"
    command git -C "$REPO_DIR" init -q
    command git -C "$REPO_DIR" config user.email t@t.test
    command git -C "$REPO_DIR" config user.name test

    command cat >"$REPO_DIR/Dockerfile" <<'DOCKER'
ARG RUST_VERSION=1.95.0
ARG PYTHON_VERSION=3.13.0
DOCKER
    command git -C "$REPO_DIR" add Dockerfile
    command git -C "$REPO_DIR" commit -qm base
    local base
    base="$(command git -C "$REPO_DIR" rev-parse HEAD)"

    if [ -n "$new_value" ]; then
        command sed -i.bak "s/^ARG ${change_arg}=.*/ARG ${change_arg}=${new_value}/" "$REPO_DIR/Dockerfile"
        command rm -f "$REPO_DIR/Dockerfile.bak"
        command git -C "$REPO_DIR" commit -qam "bump ${change_arg}"
    fi
    local head
    head="$(command git -C "$REPO_DIR" rev-parse HEAD)"
    echo "$base $head"
}

# Write a fake `gh` to an absolute path; the script calls it via its `GH`
# override. The fake reads SIBLING_PRESENT from its environment.
install_gh_stub() {
    GH_STUB="$TEST_TEMP_DIR/gh"
    command cat >"$GH_STUB" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "api" ]; then
    [ "${SIBLING_PRESENT:-0}" = "1" ] && exit 0 || exit 1
fi
exit 0   # `workflow run` and anything else succeed; the script logs the dispatch
STUB
    command chmod +x "$GH_STUB"
}

# Run the dispatcher against the throwaway repo with the fake gh injected by
# absolute path (GH=) and SIBLING_PRESENT forwarded as external-command env
# assignments, both of which reliably reach the script.
# Usage: run_dispatch <present:0|1> <base> <head> [extra args...]
run_dispatch() {
    local present="$1" base="$2" head="$3"
    shift 3
    DISPATCH_PROJECT_ROOT="$TEST_TEMP_DIR/repo" \
        GH="$GH_STUB" \
        SIBLING_PRESENT="$present" \
        "$DISPATCH_SCRIPT" --base "$base" --head "$head" "$@" 2>&1
}

test_dispatches_when_sibling_present() {
    install_gh_stub
    read -r base head < <(make_repo RUST_VERSION 1.96.0)
    local out
    out="$(run_dispatch 1 "$base" "$head" --dry-run)"
    assert_contains "$out" "PLAN dispatch rust 1.96.0" "bumped rust with present sibling should plan a dispatch"
    assert_contains "$out" "tuple=debian-12-amd64" "plan should carry the pilot tuple"
}

test_defers_when_sibling_absent() {
    install_gh_stub
    read -r base head < <(make_repo RUST_VERSION 1.96.0)
    local out
    out="$(run_dispatch 0 "$base" "$head" --dry-run)"
    assert_contains "$out" "PLAN defer rust 1.96.0" "absent sibling should defer"
    assert_not_contains "$out" "PLAN dispatch" "must not dispatch when sibling lacks the version"
}

test_ignores_non_luggage_tool_change() {
    install_gh_stub
    read -r base head < <(make_repo PYTHON_VERSION 3.13.1)
    local out
    out="$(run_dispatch 1 "$base" "$head" --dry-run)"
    assert_contains "$out" "no change: rust" "a non-luggage ARG bump should not trigger rust evidence"
    assert_not_contains "$out" "PLAN dispatch" "no luggage tool changed => no dispatch"
}

test_no_change_no_dispatch() {
    install_gh_stub
    read -r base head < <(make_repo RUST_VERSION "") # no second commit
    local out
    out="$(run_dispatch 1 "$base" "$head" --dry-run)"
    assert_contains "$out" "no change: rust" "identical base/head => nothing changed"
    assert_not_contains "$out" "PLAN dispatch" "no diff => no dispatch"
}

test_real_run_reaches_dispatch() {
    install_gh_stub
    read -r base head < <(make_repo RUST_VERSION 1.96.0)
    # Non-dry-run with a present sibling: the script reaches dispatch_evidence,
    # the stub's `gh workflow run` succeeds, and the script reports the dispatch.
    local out
    out="$(run_dispatch 1 "$base" "$head")"
    assert_contains "$out" "dispatching evidence run for rust@1.96.0" "non-dry-run with present sibling dispatches"
    assert_contains "$out" "1 dispatched" "summary should count the dispatch"
}

run_test test_dispatches_when_sibling_present "dispatches when sibling catalog has the version"
run_test test_defers_when_sibling_absent "defers when sibling catalog lacks the version"
run_test test_ignores_non_luggage_tool_change "ignores non-luggage ARG bumps"
run_test test_no_change_no_dispatch "no Dockerfile change => no dispatch"
run_test test_real_run_reaches_dispatch "non-dry-run reaches dispatch for the bumped version"

generate_report
