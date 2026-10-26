#!/usr/bin/env bash
# Unit tests: evidence-run.yml keeps the batched-ingest shape.
#
# Before batching, each evidence cell opened its own containers-db PR and its
# own tracking issue, so one push produced up to 200 PRs (conflicting on
# shared version files) and dozens of duplicate issues, and cells read
# containers-db main, which raced DB changes that needed a matching luggage
# change. These checks fail if any of that comes back.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "evidence-run.yml batched-ingest shape"

WF="$PROJECT_ROOT/.github/workflows/evidence-run.yml"

# _job_block <job> — the YAML of one top-level job (from its key to the next).
_job_block() {
    /usr/bin/awk -v job="$1" '
        $0 ~ "^  " job ":$" { on = 1; print; next }
        on && /^  [a-z_-]+:$/ { exit }
        on { print }
    ' "$WF"
}

test_cells_install_as_the_container_user() {
    # Evidence must take the run-as-user path real containers take
    # (lib/features/rust.sh passes --user): installing as root hid an Alpine
    # post-install PATH bug while every Alpine cell passed (#1165).
    local cell
    cell="$(_job_block evidence | /usr/bin/grep -vE '^[[:space:]]*#')"
    if /usr/bin/grep -qE 'luggage install .*--user runner' <<<"$cell"; then
        assert_true true "luggage install runs with --user runner"
    else
        assert_true false "evidence luggage install must pass --user runner"
    fi
}

test_cells_open_no_prs_or_issues() {
    local cell
    # Comment lines excluded: prose may mention the scripts it no longer runs.
    cell="$(_job_block evidence | /usr/bin/grep -vE '^[[:space:]]*#')"
    if /usr/bin/grep -qE 'ingest-evidence(-batch)?\.sh|gh pr create|open_or_update_tracking_issue|open_run_tracking_issue' <<<"$cell"; then
        assert_true false "the evidence (cell) job must not ingest or file issues; that is the collect job's"
    else
        assert_true true "cells only record and upload"
    fi
}

test_collect_job_batches_into_one_pr() {
    local collect
    collect="$(_job_block collect)"
    assert_contains "$collect" "ingest-evidence-batch.sh" "collect ingests the whole run in one batch"
    assert_contains "$collect" "open_run_tracking_issue" "collect files one issue per run"
    assert_contains "$collect" "always()" "collect runs even when some cells failed"
}

test_artifact_name_is_per_cell() {
    # Per-tuple names collided once a tuple had many versions.
    assert_file_contains "$WF" 'name: evidence-row-${{ matrix.tool }}-${{ matrix.version }}-${{ matrix.tuple }}' \
        "artifact name includes tool, version, and tuple"
}

# _db_sources_run — the executable lines of the "Collect open evidence PRs"
# step's run: block (comments dropped, so prose cannot satisfy a pin).
_db_sources_run() {
    /usr/bin/awk '
        /- name: Collect open evidence PRs/ { on = 1; next }
        on && /- name: / { exit }
        on { print }
    ' "$WF" | /usr/bin/grep -vE '^[[:space:]]*#'
}

# _db_sources_fn — the executable lines of evidence_db_sources, which holds
# the step's logic since #1328 (its behavior is unit-tested in
# tests/unit/bin/lib/evidence-sources.sh; these pins keep its shape).
_db_sources_fn() {
    /usr/bin/awk '/^evidence_db_sources\(\) \{/ { on = 1 } on { print } on && /^\}$/ { exit }' \
        "$PROJECT_ROOT/bin/lib/evidence-sources.sh" | /usr/bin/grep -vE '^[[:space:]]*#'
}

test_open_pr_sources_step_calls_the_lib() {
    # The step is a call, so the fail-closed guards stay where tests reach them.
    local run
    run="$(_db_sources_run)"
    assert_contains "$run" 'source bin/lib/evidence-sources.sh' "the step sources the lib"
    assert_contains "$run" 'SOURCES=$(evidence_db_sources "$PWD/_db" "$PWD" "$(date -u +%s)")' \
        "and resolves its sources through evidence_db_sources"
    assert_not_contains "$run" 'gh pr list' "no inline listing is left in the step"
    # The setup job's checkout is sparse: a lib it sources but does not list
    # is missing on the runner, and the step fails before resolving anything.
    local lib sparse
    sparse="$(/usr/bin/awk '
        /- name: Checkout catalog and base-image tree/ { on = 1; next }
        on && /- name: / { exit }
        on { print }
    ' "$WF")"
    for lib in evidence-sources.sh evidence-matrix.sh evidence-epoch.sh; do
        assert_contains "$sparse" "bin/lib/$lib" "the setup checkout lists bin/lib/$lib"
    done
}

test_open_pr_sources_count_only_added_rows() {
    # #1327: an open PR's whole head tree re-asserted rows main had since
    # revoked; only the rows it adds over its merge-base may count.
    local fn
    fn="$(_db_sources_fn)"
    assert_contains "$fn" 'evidence_pr_rows "$work/_db_pr/$n/base" "$work/_db_pr/$n/head" "$work/_db_pr/$n/rows"' \
        "each PR is reduced to its added rows, base before head"
    assert_contains "$fn" 'sources="$sources:$work/_db_pr/$n/rows"' "the rows tree joins the sources"
    assert_not_contains "$fn" 'sources="$sources:$work/_db_pr/$n/head"' "the head tree itself never joins them"
}

test_open_pr_sources_pin_the_main_read() {
    # Merge-bases and the merged check use the fetched main SHA, not the
    # moving ref, or a PR that merges mid-step lands in neither source.
    local fn
    fn="$(_db_sources_fn)"
    assert_contains "$fn" 'main_sha="$(command git -C "$db" rev-parse HEAD)"' "the main read's SHA is captured"
    assert_contains "$fn" 'compare/$main_sha...$head_sha' "the merge-base is taken against it"
    assert_contains "$fn" 'compare/$merge...$main_sha' "the merged check is too"
    assert_not_contains "$fn" 'compare/main...' "never against live main"
}

test_open_pr_sources_skip_via_the_decision() {
    # The skip rules themselves are evidence_pr_skip's, behavior-tested in
    # tests/unit/bin/lib/evidence-matrix.sh (#1446). Here: the loop asks it,
    # after the head fetch, with the re-read state.
    local fn fetch_line state_line skip_line
    fn="$(_db_sources_fn)"
    assert_contains "$fn" '--json state,mergeCommit' "each PR's state is re-read"
    assert_contains "$fn" 'verdict="$(evidence_pr_skip "$state" "$merge" "$in_main")" || return 1' \
        "the skip decision is evidence_pr_skip's, and its failure is fatal"
    fetch_line="$(/usr/bin/grep -n 'refs/pull/$n/head' <<<"$fn" | /usr/bin/cut -d: -f1)"
    state_line="$(/usr/bin/grep -n 'json state,mergeCommit' <<<"$fn" | /usr/bin/cut -d: -f1)"
    skip_line="$(/usr/bin/grep -n 'evidence_pr_skip "' <<<"$fn" | /usr/bin/cut -d: -f1)"
    assert_true "[ ${fetch_line:-0} -gt 0 ] && [ ${state_line:-0} -gt ${fetch_line:-0} ] && [ ${skip_line:-0} -gt ${state_line:-0} ]" \
        "the state is read after the head fetch, and decided on after that"
}

test_cells_install_from_the_vendored_catalog() {
    local cell
    cell="$(_job_block evidence)"
    assert_contains "$cell" 'crates/luggage/testdata/catalog:/catalog:ro' \
        "cells install against the catalog luggage was built with"
    if /usr/bin/grep -q 'clone.*containers-db' <<<"$cell"; then
        assert_true false "cells must not clone containers-db (races DB changes against luggage)"
    else
        assert_true true "cells do not read containers-db main"
    fi
}

run_test test_cells_install_as_the_container_user "cells install as the container user (--user runner)"
run_test test_cells_open_no_prs_or_issues "cells open no PRs or issues"
run_test test_collect_job_batches_into_one_pr "collect job batches into one PR and one issue"
run_test test_artifact_name_is_per_cell "artifact name is per cell"
run_test test_open_pr_sources_step_calls_the_lib "open-PR sources step calls evidence_db_sources (#1328)"
run_test test_open_pr_sources_count_only_added_rows "open-PR sources count only the rows each PR adds (#1327)"
run_test test_open_pr_sources_pin_the_main_read "open-PR sources take merge-bases against the fetched main"
run_test test_open_pr_sources_skip_via_the_decision "open-PR sources skip through evidence_pr_skip (#1446)"
run_test test_cells_install_from_the_vendored_catalog "cells install from the vendored catalog"

generate_report
