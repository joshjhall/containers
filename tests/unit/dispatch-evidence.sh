#!/usr/bin/env bash
# Unit tests for bin/dispatch-evidence.sh — the auto-patch post-merge step that
# triggers luggage evidence runs for bumped, luggage-managed tools (#506 Phase 2,
# #645 full-matrix enumeration).
#
# These tests drive the script against a throwaway git repo (DISPATCH_PROJECT_ROOT)
# and a fake `gh` injected via the script's `GH` override (an absolute path —
# PATH-shadowing is unreliable here because the shell re-initializes PATH from
# the profile on each bash startup). No network or real dispatch happens. The
# fake `gh`'s behavior is controlled by two env knobs:
#   SIBLING_PRESENT=1  -> `gh api .../contents/...` returns the version JSON
#   SIBLING_PRESENT=0  -> `gh api` exits 1 (404 — version absent)
#   SUPPORTED_CELLS    -> space-separated `<os>-<osv>-<arch>` slugs the canned
#                         version JSON claims `supported` (default debian-12-amd64)
# The helper calls `gh api ... --jq '.content' | base64 -d`, so the stub emits
# the version JSON base64-encoded (what `--jq '.content'` would print). Real `jq`
# is used by the script — the tests do NOT stub it.
# `gh workflow run` always exits 0 (the script's own stdout reports the dispatch).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "dispatch-evidence.sh tests"

DISPATCH_SCRIPT="$PROJECT_ROOT/bin/dispatch-evidence.sh"

# Build a throwaway repo with a Dockerfile, then change one ARG in a second
# commit, and stage a configurable set of base-image Dockerfiles so the
# dispatcher's available_base_tuples() has something to intersect against.
# Echoes "<base_sha> <head_sha>". The repo lives at a deterministic path
# ($TEST_TEMP_DIR/repo) so callers don't depend on a variable surviving the
# process-substitution subshell this runs in.
# Args:
#   $1 change_arg   ARG to bump (empty new_value => no second commit)
#   $2 new_value    new ARG value
#   $3 staged_cells space-separated `<os>-<osv>-<arch>` tuples to materialize as
#                   base-images/<os>/<osv>/<arch>/Dockerfile (default debian-12-amd64)
make_repo() {
    local change_arg="$1" new_value="$2" staged_cells="${3:-debian-12-amd64}"
    local REPO_DIR="$TEST_TEMP_DIR/repo"
    command rm -rf "$REPO_DIR"
    command mkdir -p "$REPO_DIR"
    command git -C "$REPO_DIR" init -q
    command git -C "$REPO_DIR" config user.email t@t.test
    command git -C "$REPO_DIR" config user.name test

    command cat >"$REPO_DIR/Dockerfile" <<'DOCKER'
ARG RUST_VERSION=1.95.0
ARG PYTHON_VERSION=3.13.0
DOCKER

    # Stage the available base-image tree: one empty Dockerfile per cell.
    local cell os osv arch
    for cell in $staged_cells; do
        IFS='-' read -r os osv arch <<<"$cell"
        command mkdir -p "$REPO_DIR/base-images/$os/$osv/$arch"
        command touch "$REPO_DIR/base-images/$os/$osv/$arch/Dockerfile"
    done

    command git -C "$REPO_DIR" add -A
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
# override. The fake reads SIBLING_PRESENT / SUPPORTED_CELLS from its
# environment and emits the version JSON base64-encoded for `api`, mirroring
# `gh api ... --jq '.content'` output that the helper then base64-decodes. The
# support_matrix is built from SUPPORTED_CELLS so each test shapes the claimed
# cells independently.
install_gh_stub() {
    GH_STUB="$TEST_TEMP_DIR/gh"
    command cat >"$GH_STUB" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "api" ]; then
    [ "${SIBLING_PRESENT:-0}" = "1" ] || exit 1   # 404 — version absent
    cells="${SUPPORTED_CELLS:-debian-12-amd64}"
    rows=""
    for cell in $cells; do
        IFS='-' read -r os osv arch <<<"$cell"
        row="{\"os\":\"${os}\",\"os_version\":\"${osv}\",\"arch\":\"${arch}\",\"status\":\"supported\"}"
        if [ -z "$rows" ]; then rows="$row"; else rows="${rows},${row}"; fi
    done
    JSON="{\"support_matrix\":[${rows}],\"tested\":[]}"
    # Emit base64 (no newlines), as `gh api --jq '.content'` would for the file.
    command printf '%s' "$JSON" | command base64 | command tr -d '\n'
    exit 0
fi
exit 0   # `workflow run` and anything else succeed; the script logs the dispatch
STUB
    command chmod +x "$GH_STUB"
}

# Run the dispatcher against the throwaway repo with the fake gh injected by
# absolute path (GH=) and SIBLING_PRESENT / SUPPORTED_CELLS forwarded as
# external-command env assignments, all of which reliably reach the script.
# An EVIDENCE_TUPLE already in the environment is honored (override path).
# Usage: run_dispatch <present:0|1> <supported_cells> <base> <head> [extra args...]
run_dispatch() {
    local present="$1" cells="$2" base="$3" head="$4"
    shift 4
    DISPATCH_PROJECT_ROOT="$TEST_TEMP_DIR/repo" \
        GH="$GH_STUB" \
        SIBLING_PRESENT="$present" \
        SUPPORTED_CELLS="$cells" \
        "$DISPATCH_SCRIPT" --base "$base" --head "$head" "$@" 2>&1
}

test_dispatches_when_sibling_present() {
    install_gh_stub
    # Default: claims and stages only debian-12-amd64 — the one published cell.
    read -r base head < <(make_repo RUST_VERSION 1.96.0)
    local out
    out="$(run_dispatch 1 "debian-12-amd64" "$base" "$head" --dry-run)"
    assert_contains "$out" "PLAN dispatch rust 1.96.0" "bumped rust with present sibling should plan a dispatch"
    assert_contains "$out" "tuple=debian-12-amd64" "plan should carry the pilot tuple"
}

test_defers_when_sibling_absent() {
    install_gh_stub
    read -r base head < <(make_repo RUST_VERSION 1.96.0)
    local out
    out="$(run_dispatch 0 "debian-12-amd64" "$base" "$head" --dry-run)"
    assert_contains "$out" "PLAN defer rust 1.96.0" "absent sibling should defer"
    assert_not_contains "$out" "PLAN dispatch" "must not dispatch when sibling lacks the version"
}

test_ignores_non_luggage_tool_change() {
    install_gh_stub
    read -r base head < <(make_repo PYTHON_VERSION 3.13.1)
    local out
    out="$(run_dispatch 1 "debian-12-amd64" "$base" "$head" --dry-run)"
    assert_contains "$out" "no change: rust" "a non-luggage ARG bump should not trigger rust evidence"
    assert_not_contains "$out" "PLAN dispatch" "no luggage tool changed => no dispatch"
}

test_no_change_no_dispatch() {
    install_gh_stub
    read -r base head < <(make_repo RUST_VERSION "") # no second commit
    local out
    out="$(run_dispatch 1 "debian-12-amd64" "$base" "$head" --dry-run)"
    assert_contains "$out" "no change: rust" "identical base/head => nothing changed"
    assert_not_contains "$out" "PLAN dispatch" "no diff => no dispatch"
}

test_real_run_reaches_dispatch() {
    install_gh_stub
    read -r base head < <(make_repo RUST_VERSION 1.96.0)
    # Non-dry-run with a present sibling: the script reaches dispatch_evidence,
    # the stub's `gh workflow run` succeeds, and the script reports the dispatch.
    local out
    out="$(run_dispatch 1 "debian-12-amd64" "$base" "$head")"
    assert_contains "$out" "dispatching evidence run for rust@1.96.0" "non-dry-run with present sibling dispatches"
    assert_contains "$out" "1 dispatched" "summary should count the dispatch"
}

test_dispatches_full_matrix() {
    install_gh_stub
    # Claims two cells, both staged as available => two distinct dispatches.
    read -r base head < <(make_repo RUST_VERSION 1.96.0 "debian-12-amd64 debian-13-amd64")
    local out
    out="$(run_dispatch 1 "debian-12-amd64 debian-13-amd64" "$base" "$head" --dry-run)"
    assert_contains "$out" "tuple=debian-12-amd64" "should plan the debian-12 cell"
    assert_contains "$out" "tuple=debian-13-amd64" "should plan the debian-13 cell"
    assert_contains "$out" "2 dispatched" "both claimed+available cells should dispatch"
}

test_intersects_with_available() {
    install_gh_stub
    # Claims debian-13 + debian-12, but only debian-12 has a published base image.
    read -r base head < <(make_repo RUST_VERSION 1.96.0 "debian-12-amd64")
    local out
    out="$(run_dispatch 1 "debian-13-amd64 debian-12-amd64" "$base" "$head" --dry-run)"
    assert_contains "$out" "tuple=debian-12-amd64" "the staged cell should dispatch"
    assert_not_contains "$out" "tuple=debian-13-amd64" "the unstaged cell must NOT dispatch"
    assert_contains "$out" "1 dispatched" "only the available cell dispatches"
}

test_empty_intersection_no_dispatch() {
    install_gh_stub
    # Claims only debian-13, but only debian-12 is staged => empty intersection.
    read -r base head < <(make_repo RUST_VERSION 1.96.0 "debian-12-amd64")
    local out
    out="$(run_dispatch 1 "debian-13-amd64" "$base" "$head" --dry-run)"
    assert_contains "$out" "no supported tuples available for rust@1.96.0" "empty intersection should report cleanly"
    assert_not_contains "$out" "PLAN dispatch" "empty intersection must not dispatch"
    assert_contains "$out" "0 dispatched" "nothing dispatched"
}

test_evidence_tuple_override_single() {
    install_gh_stub
    # Claims two cells, but EVIDENCE_TUPLE pins a single one regardless.
    read -r base head < <(make_repo RUST_VERSION 1.96.0 "debian-12-amd64 debian-13-amd64")
    local out
    out="$(EVIDENCE_TUPLE=alpine-3.21-arm64 \
        DISPATCH_PROJECT_ROOT="$TEST_TEMP_DIR/repo" \
        GH="$GH_STUB" \
        SIBLING_PRESENT=1 \
        SUPPORTED_CELLS="debian-12-amd64 debian-13-amd64" \
        "$DISPATCH_SCRIPT" --base "$base" --head "$head" --dry-run 2>&1)"
    assert_contains "$out" "tuple=alpine-3.21-arm64" "override tuple should be dispatched verbatim"
    assert_not_contains "$out" "tuple=debian-12-amd64" "override bypasses the claimed matrix"
    assert_contains "$out" "1 dispatched" "override dispatches exactly one"
}

run_test test_dispatches_when_sibling_present "dispatches when sibling catalog has the version"
run_test test_defers_when_sibling_absent "defers when sibling catalog lacks the version"
run_test test_ignores_non_luggage_tool_change "ignores non-luggage ARG bumps"
run_test test_no_change_no_dispatch "no Dockerfile change => no dispatch"
run_test test_real_run_reaches_dispatch "non-dry-run reaches dispatch for the bumped version"
run_test test_dispatches_full_matrix "dispatches one run per claimed+available cell"
run_test test_intersects_with_available "intersects claimed cells with available base tuples"
run_test test_empty_intersection_no_dispatch "empty intersection dispatches nothing, exits clean"
run_test test_evidence_tuple_override_single "EVIDENCE_TUPLE overrides to a single tuple"

generate_report
