#!/usr/bin/env bash
# Unit tests for bin/dispatch-evidence-for-tuple.sh — the build-base-images
# post-publish step that re-runs evidence when a tuple is rebuilt to a new
# digest (#640).
#
# These tests drive the script against a throwaway git repo (DISPATCH_PROJECT_ROOT)
# and a fake `gh` injected via the script's `GH` override (an absolute path —
# PATH-shadowing is unreliable here because the shell re-initializes PATH from
# the profile on each bash startup). No network or real dispatch happens. The
# fake `gh`'s behavior is controlled by three env knobs that shape the canned
# containers-db version JSON it returns:
#   SIBLING_PRESENT=1 -> `gh api .../contents/...` returns the version JSON
#   SIBLING_PRESENT=0 -> `gh api` exits 1 (404 — version absent)
#   SUPPORTS_TUPLE=1  -> support_matrix claims debian-12-amd64 supported
#   SUPPORTS_TUPLE=0  -> support_matrix claims only debian-13-amd64 (not our tuple)
#   TESTED_DIGEST=<d> -> a passing tested[] row carries digest <d> (empty => no rows)
# The helper calls `gh api ... --jq '.content' | base64 -d`, so the stub emits
# the version JSON base64-encoded (what `--jq '.content'` would print).
# `gh workflow run` always exits 0 (the script's own stdout reports the dispatch).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "dispatch-evidence-for-tuple.sh tests"

DISPATCH_SCRIPT="$PROJECT_ROOT/bin/dispatch-evidence-for-tuple.sh"

# A valid-shaped published digest (sha256: + 64 hex). The "newest tested"
# digest in the no-op case is set equal to this; the change case differs.
NEW_DIGEST="sha256:$(command printf 'a%.0s' {1..64})"
OTHER_DIGEST="sha256:$(command printf 'b%.0s' {1..64})"

# Build a throwaway repo with a Dockerfile carrying the luggage-managed ARG.
# Echoes nothing; the repo lives at a deterministic path ($TEST_TEMP_DIR/repo).
make_repo() {
    local REPO_DIR="$TEST_TEMP_DIR/repo"
    command mkdir -p "$REPO_DIR"
    command cat >"$REPO_DIR/Dockerfile" <<'DOCKER'
ARG RUST_VERSION=1.95.0
ARG PYTHON_VERSION=3.13.0
DOCKER
}

# Write a fake `gh` to an absolute path; the script calls it via its `GH`
# override. The fake reads SIBLING_PRESENT / SUPPORTS_TUPLE / TESTED_DIGEST from
# its environment and emits the version JSON base64-encoded for `api`, mirroring
# `gh api ... --jq '.content'` output that the helper then base64-decodes.
install_gh_stub() {
    GH_STUB="$TEST_TEMP_DIR/gh"
    command cat >"$GH_STUB" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "api" ]; then
    [ "${SIBLING_PRESENT:-0}" = "1" ] || exit 1   # 404 — version absent
    if [ "${SUPPORTS_TUPLE:-1}" = "1" ]; then
        SM='[{"os":"debian","os_version":"12","arch":"amd64","status":"supported"}]'
    else
        SM='[{"os":"debian","os_version":"13","arch":"amd64","status":"supported"}]'
    fi
    if [ -n "${TESTED_DIGEST:-}" ]; then
        TESTED="[{\"os\":\"debian\",\"os_version\":\"12\",\"arch\":\"amd64\",\"result\":\"pass\",\"image_digest\":\"${TESTED_DIGEST}\",\"tested_at\":\"2026-06-01T00:00:00Z\"}]"
    else
        TESTED='[]'
    fi
    JSON="{\"support_matrix\":${SM},\"tested\":${TESTED}}"
    # Emit base64 (no newlines), as `gh api --jq '.content'` would for the file.
    command printf '%s' "$JSON" | command base64 | command tr -d '\n'
    exit 0
fi
exit 0   # `workflow run` and anything else succeed; the script logs the dispatch
STUB
    command chmod +x "$GH_STUB"
}

# Run the dispatcher against the throwaway repo with the fake gh injected by
# absolute path (GH=) and the catalog-shape knobs forwarded as external-command
# env assignments, all of which reliably reach the script.
# Usage: run_dispatch <present> <supports> <tested_digest> [extra args...]
run_dispatch() {
    local present="$1" supports="$2" tested="$3"
    shift 3
    DISPATCH_PROJECT_ROOT="$TEST_TEMP_DIR/repo" \
        GH="$GH_STUB" \
        SIBLING_PRESENT="$present" \
        SUPPORTS_TUPLE="$supports" \
        TESTED_DIGEST="$tested" \
        "$DISPATCH_SCRIPT" --tuple debian-12-amd64 --digest "$NEW_DIGEST" "$@" 2>&1
}

test_dispatches_on_digest_change() {
    install_gh_stub
    make_repo
    local out
    out="$(run_dispatch 1 1 "$OTHER_DIGEST" --dry-run)"
    assert_contains "$out" "PLAN dispatch rust 1.95.0" "a newer digest than the tested row should plan a dispatch"
    assert_contains "$out" "digest=${NEW_DIGEST}" "plan should carry the new digest"
}

test_dispatches_when_never_tested() {
    install_gh_stub
    make_repo
    local out
    # Empty tested[] — the real testdata catalog ships tested:[], so this is the
    # common first-evidence case and must dispatch.
    out="$(run_dispatch 1 1 "" --dry-run)"
    assert_contains "$out" "PLAN dispatch rust 1.95.0" "no prior evidence should plan a dispatch"
}

test_noop_when_digest_matches_newest() {
    install_gh_stub
    make_repo
    local out
    out="$(run_dispatch 1 1 "$NEW_DIGEST" --dry-run)"
    assert_contains "$out" "no-op:" "matching newest tested digest should be a no-op"
    assert_not_contains "$out" "PLAN dispatch" "must not dispatch when the digest is unchanged"
}

test_defers_when_sibling_absent() {
    install_gh_stub
    make_repo
    local out
    out="$(run_dispatch 0 1 "$OTHER_DIGEST" --dry-run)"
    assert_contains "$out" "PLAN defer rust 1.95.0" "absent sibling version should defer"
    assert_not_contains "$out" "PLAN dispatch" "must not dispatch when sibling lacks the version"
}

test_skips_unclaimed_tuple() {
    install_gh_stub
    make_repo
    local out
    # support_matrix claims only debian-13 — our debian-12 rebuild is not claimed.
    out="$(run_dispatch 1 0 "$OTHER_DIGEST" --dry-run)"
    assert_contains "$out" "skip: rust@1.95.0 does not claim debian-12-amd64" "unclaimed tuple should skip"
    assert_not_contains "$out" "PLAN dispatch" "must not dispatch a tuple the tool doesn't claim"
}

test_real_run_reaches_dispatch() {
    install_gh_stub
    make_repo
    local out
    # Non-dry-run, digest changed, sibling present: reaches dispatch_evidence;
    # the stub's `gh workflow run` succeeds and the script reports the dispatch.
    out="$(run_dispatch 1 1 "$OTHER_DIGEST")"
    assert_contains "$out" "dispatching evidence run for rust@1.95.0 on debian-12-amd64" "non-dry-run with a changed digest dispatches"
    assert_contains "$out" "1 dispatched" "summary should count the dispatch"
}

run_test test_dispatches_on_digest_change "dispatches when the new digest differs from the newest tested row"
run_test test_dispatches_when_never_tested "dispatches when there is no prior evidence"
run_test test_noop_when_digest_matches_newest "no-op when the new digest matches the newest tested row"
run_test test_defers_when_sibling_absent "defers when the sibling catalog lacks the version"
run_test test_skips_unclaimed_tuple "skips a tool that does not claim the rebuilt tuple"
run_test test_real_run_reaches_dispatch "non-dry-run reaches dispatch for a changed digest"

generate_report
