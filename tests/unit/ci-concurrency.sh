#!/usr/bin/env bash
# Unit tests for ci.yml's workflow-level concurrency group (#1560).
#
# A push to a PR branch must cancel the in-flight CI/CD Pipeline run for the
# old head, while runs for main/v5/auto-patch/**/tags are never cancelled —
# release and auto-patch read those results. Non-PR runs therefore get a
# run-unique group: GitHub displaces a *pending* run when a newer one joins
# the same group even with cancel-in-progress false, so a per-ref group would
# still drop main runs.
#
# Also pins evidence-run.yml's cancel-in-progress: it cancels only dry-run
# pull_request runs (#1591) — push/dispatch runs ingest, and an interrupted
# ingest can leave a half-pushed branch. The full evidence group shape is
# covered by tests/unit/evidence-run-shape.sh; test-pr.yml's own group by
# tests/unit/required-checks-pr-tier.sh.
#
# Run via: ./tests/run_unit_tests.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/framework.sh
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "CI/CD Pipeline concurrency"

WORKFLOWS_DIR="$PROJECT_ROOT/.github/workflows"

# shellcheck source=tests/framework/helpers/required-checks.sh
source "$SCRIPT_DIR/../framework/helpers/required-checks.sh"

# Overridable so a mutation check can point the suite at a scratch copy;
# never mutate the tracked file to prove a row bites.
CI_WORKFLOW="${CI_WORKFLOW:-$WORKFLOWS_DIR/ci.yml}"
EVIDENCE_WORKFLOW="${EVIDENCE_WORKFLOW:-$WORKFLOWS_DIR/evidence-run.yml}"

# The PR branch keys on the PR number; every other event keys on run_id, so
# no two non-PR runs ever share a group.
test_ci_concurrency_group_shape() {
    require_yq || return 0
    local out

    out=$(run_yq '.concurrency.group' "$CI_WORKFLOW") || out="FAILED"
    assert_equals \
        "ci-\${{ github.event_name == 'pull_request' && format('pr-{0}', github.event.pull_request.number) || format('run-{0}', github.run_id) }}" \
        "$out" "ci.yml group is per-PR for pull_request, run-unique otherwise"
}

# Only pull_request runs may cancel. A literal `true` here would cancel
# in-flight main/tag runs; `false` would leave stale PR runs holding slots.
test_ci_cancel_only_on_pull_request() {
    require_yq || return 0
    local out

    out=$(run_yq '.concurrency["cancel-in-progress"]' "$CI_WORKFLOW") || out="FAILED"
    assert_equals "\${{ github.event_name == 'pull_request' }}" "$out" \
        "ci.yml cancels in-progress runs only on pull_request"
}

# A job-level concurrency block would shadow the workflow-level one for that
# job (and a shared job group would re-introduce cross-run displacement).
test_ci_has_no_job_level_concurrency() {
    require_yq || return 0
    local out

    out=$(run_yq '[.jobs[] | select(has("concurrency"))] | length' "$CI_WORKFLOW") || out="FAILED"
    assert_equals "0" "$out" "no ci.yml job overrides the workflow concurrency group"
}

# Only dry-run pull_request runs may cancel. A literal `true` would cancel an
# in-flight main ingest; a literal `false` re-opens #1591's wasted PR runs.
test_evidence_run_cancels_only_pr() {
    require_yq || return 0
    local out

    out=$(run_yq '.concurrency["cancel-in-progress"]' "$EVIDENCE_WORKFLOW") || out="FAILED"
    assert_equals "\${{ github.event_name == 'pull_request' }}" "$out" \
        "evidence-run.yml cancels only pull_request runs, never an ingest"
}

run_test test_ci_concurrency_group_shape "ci.yml concurrency group keys PRs by number, others by run_id (#1560)"
run_test test_ci_cancel_only_on_pull_request "ci.yml cancels only superseded pull_request runs (#1560)"
run_test test_ci_has_no_job_level_concurrency "ci.yml jobs inherit the workflow concurrency group"
run_test test_evidence_run_cancels_only_pr "evidence-run.yml cancels only dry-run pull_request runs (#1591)"

generate_report
