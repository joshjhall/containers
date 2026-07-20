#!/usr/bin/env bash
# Unit tests for GOLEM_ID attribution in the stibbons agent entrypoint.
#
# A container golem's librarian Notification feed rows are identified by
# $GOLEM_ID (golem-notify.sh's first ladder rung). Unlike a worktree golem —
# which gets `-e GOLEM_ID=golem-$N` from golem-launch.sh — a container golem has
# no launch-stamped id, so the entrypoint derives one from AGENT_ISSUE on the
# golem-pipeline path (issue #758). Without it the ladder falls through to the
# `golem-?` placeholder and the row is unattributable.
#
# The derivation is a small linear block in agent-entrypoint.sh, not a function,
# so this test EXTRACTS that block from the real script (same `command sed -n`
# approach as tests/unit/runtime/entrypoint.sh) and exercises it in isolation —
# no re-implementation, so the test tracks the production logic.

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Agent Entrypoint GOLEM_ID Attribution"

ENTRYPOINT="$PROJECT_ROOT/crates/stibbons/src/agent/scripts/agent-entrypoint.sh"

# Extract the GOLEM_ID derivation block (the `if [[ -z ... GOLEM_ID ...]]` guard)
# from the real entrypoint, so the test runs the actual production logic.
_GOLEM_ID_SNIPPET="$RESULTS_DIR/_golem_id_derive.sh"
command sed -n '/^if \[\[ -z "${GOLEM_ID:-}" \]\]; then$/,/^fi$/p' \
    "$ENTRYPOINT" >"$_GOLEM_ID_SNIPPET"

# Runs the extracted block with a given ISSUE and (optionally) a pre-set
# GOLEM_ID, and echoes the resulting GOLEM_ID.
derive_golem_id() {
    local issue="$1"
    # shellcheck disable=SC2034  # ISSUE is read by the sourced snippet
    local ISSUE="$issue"
    # shellcheck source=/dev/null
    source "$_GOLEM_ID_SNIPPET"
    printf '%s' "${GOLEM_ID:-}"
}

# Test: the block is present and non-empty (guards against a silent extraction
# miss that would make every derivation test vacuously pass).
test_snippet_extracted() {
    assert_file_exists "$_GOLEM_ID_SNIPPET" "GOLEM_ID snippet should be extracted"
    assert_contains "$(command cat "$_GOLEM_ID_SNIPPET")" 'GOLEM_ID="golem-${ISSUE}"' \
        "Extracted snippet should contain the golem-\${ISSUE} derivation"
}

# Test: with GOLEM_ID unset, derive golem-{issue} from AGENT_ISSUE.
test_derives_from_issue() {
    unset GOLEM_ID 2>/dev/null || true
    local result
    result="$(derive_golem_id 758)"
    assert_equals "golem-758" "$result" "GOLEM_ID should derive from the issue number"
}

# Test: a pre-set GOLEM_ID is honored (not clobbered) — a worktree golem or an
# orchestrator that already stamped an id keeps it.
test_respects_preset() {
    local GOLEM_ID="golem-custom"
    export GOLEM_ID
    local result
    result="$(derive_golem_id 758)"
    assert_equals "golem-custom" "$result" "A pre-set GOLEM_ID must not be clobbered"
    unset GOLEM_ID 2>/dev/null || true
}

# Run tests
run_test test_snippet_extracted "extraction: derivation block is present"
run_test test_derives_from_issue "derives golem-{issue} from AGENT_ISSUE"
run_test test_respects_preset "honors a pre-set GOLEM_ID"

# Generate test report
generate_report
