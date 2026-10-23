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

# _trigger_paths <event> — the `paths:` entries of one `on:` trigger, unquoted.
_trigger_paths() {
    /usr/bin/awk -v ev="$1" '
        $0 ~ "^  " ev ":$" { on = 1; next }
        on && /^  [a-z_]+:$/ { exit }
        on && /^    paths:$/ { inpaths = 1; next }
        on && inpaths && /^      - / { sub(/^      - /, ""); gsub(/"/, ""); print; next }
        on && inpaths { inpaths = 0 }
    ' "$WF"
}

test_trigger_paths_cover_evidence_scripts() {
    # Every evidence lib/script the jobs source or run must re-trigger the
    # workflow, or a change confined to it first runs on some unrelated push
    # to main (#1388). The file set comes from disk so a new lib is checked
    # without editing this test.
    local ev f pattern covered
    local -a scripts patterns
    scripts=("$PROJECT_ROOT"/bin/lib/evidence-*.sh "$PROJECT_ROOT"/bin/ingest-evidence*.sh)
    for ev in pull_request push; do
        mapfile -t patterns < <(_trigger_paths "$ev")
        if [ "${#patterns[@]}" -eq 0 ]; then
            assert_true false "$ev has no paths: entries to check"
            continue
        fi
        for f in "${scripts[@]}"; do
            f="${f#"$PROJECT_ROOT"/}"
            covered=false
            for pattern in "${patterns[@]}"; do
                # shellcheck disable=SC2053 # unquoted RHS: match as a glob
                if [[ "$f" == $pattern ]]; then
                    covered=true
                    break
                fi
            done
            assert_true "$covered" "$ev paths: cover $f"
        done
    done
}

run_test test_cells_install_as_the_container_user "cells install as the container user (--user runner)"
run_test test_cells_open_no_prs_or_issues "cells open no PRs or issues"
run_test test_collect_job_batches_into_one_pr "collect job batches into one PR and one issue"
run_test test_artifact_name_is_per_cell "artifact name is per cell"
run_test test_cells_install_from_the_vendored_catalog "cells install from the vendored catalog"
run_test test_trigger_paths_cover_evidence_scripts "trigger paths cover every evidence lib and script"

generate_report
