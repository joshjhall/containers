#!/usr/bin/env bash
# Unit tests for the evidence-run arms of tests/run_changed_tests.sh's
# map_to_test (#1467, #1473), split out of tests/unit/run-changed-tests.sh
# (#1480). They pin which suites an edit to evidence-run.yml or one of the
# evidence bin scripts runs at push time.

set -euo pipefail

# Source test framework
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "Changed-test mapping: evidence-run arms (#1467, #1473)"

# RUNNER and the _load_* extractors, shared with run-changed-tests.sh.
# shellcheck source=tests/lib/run-changed-tests-loaders.sh
source "$PROJECT_ROOT/tests/lib/run-changed-tests-loaders.sh"

# ============================================================================
# evidence-run.yml → evidence-run-*.sh suites (#1467)
# ============================================================================
# The workflow's pins are split across the ingest-shape and trigger-paths
# suites, neither named after it, so a workflow edit must collect both.

test_evidence_run_mapping_emits_both_suites() {
    local out
    if ! _load_map_changed_files; then
        fail_test "could not extract map_changed_files from $RUNNER"
        return 0
    fi

    out=$(command printf '%s\n' .github/workflows/evidence-run.yml | map_changed_files | command sort)
    assert_equals "$TESTS_DIR/unit/evidence-run-shape.sh
$TESTS_DIR/unit/evidence-run-trigger-paths.sh" "$out" \
        "evidence-run.yml must collect both evidence-run suites, each as its own path"
}

# The arm globs tests/unit/evidence-run-*.sh: a new sibling is picked up, an
# unrelated suite is not, and with none present the -f guard keeps the literal
# unmatched glob out.
test_evidence_run_mapping_follows_glob() {
    local root out
    if ! _load_map_to_test; then
        fail_test "could not extract map_to_test from $RUNNER"
        return 0
    fi
    root=$(/usr/bin/mktemp -d)
    /usr/bin/mkdir -p "$root/tests/unit"

    out=$(PROJECT_ROOT="$root" TESTS_DIR="$root/tests" map_to_test ".github/workflows/evidence-run.yml")
    assert_empty "$out" "no evidence-run suites must map to no test path"

    /usr/bin/touch "$root/tests/unit/evidence-run-a.sh" "$root/tests/unit/evidence-run-b.sh" \
        "$root/tests/unit/evidence-issue.sh"
    out=$(PROJECT_ROOT="$root" TESTS_DIR="$root/tests" map_to_test ".github/workflows/evidence-run.yml" | command sort)
    assert_equals "$root/tests/unit/evidence-run-a.sh
$root/tests/unit/evidence-run-b.sh" "$out" \
        "evidence-run.yml must map to exactly the evidence-run-*.sh suites present"

    /usr/bin/rm -rf "$root"
}

# ============================================================================
# evidence-run.yml's bin scripts → trigger-paths suite (#1473)
# ============================================================================
# The trigger-paths suite derives the workflow's script set from these files'
# `source` lines, so an edit confined to one of them must run it at push time,
# not only in full CI.

test_evidence_scripts_map_to_trigger_paths() {
    local out f
    if ! _load_map_to_test; then
        fail_test "could not extract map_to_test from $RUNNER"
        return 0
    fi

    # No own suite: trigger-paths is the whole push-time selection.
    for f in bin/ingest-evidence.sh bin/ingest-evidence-batch.sh bin/lib/evidence-issue.sh; do
        out=$(map_to_test "$f")
        assert_equals "$TESTS_DIR/unit/evidence-run-trigger-paths.sh" "$out" \
            "$f must map to exactly the trigger-paths suite"
    done

    # Own suite plus trigger-paths, as an exact sorted set.
    out=$(map_to_test "bin/lib/evidence-epoch.sh" | command sort)
    assert_equals "$TESTS_DIR/unit/bin/lib/evidence-epoch.sh
$TESTS_DIR/unit/evidence-run-trigger-paths.sh" "$out" \
        "bin/lib/evidence-epoch.sh must map to its own suite and trigger-paths"

    # #1482: the sources lib's suite was split along the listing / extraction
    # seam, with the gh stub and fixtures shared from tests/lib/. The exact set,
    # for the lib and its fixtures: a dropped sibling narrows push-time coverage
    # silently.
    for f in bin/lib/evidence-sources.sh tests/lib/evidence-sources-fixtures.sh; do
        out=$(map_to_test "$f" | command sort)
        assert_equals "$TESTS_DIR/unit/bin/lib/evidence-sources-extract.sh
$TESTS_DIR/unit/bin/lib/evidence-sources.sh
$TESTS_DIR/unit/evidence-run-trigger-paths.sh" "$out" \
            "$f must map to both split suites and trigger-paths"
    done

    # Scripts the workflow neither runs nor sources keep their own mapping.
    out=$(map_to_test "bin/check-versions.sh" | command sort)
    assert_equals "$TESTS_DIR/unit/bin/check-versions-checkers.sh
$TESTS_DIR/unit/bin/check-versions.sh" "$out" \
        "a non-evidence bin script must not map to trigger-paths"

    # The pattern's edge: these carry "evidence" in their names but sit outside
    # the workflow's bin/ paths: filters, so a widened pattern (bin/*evidence*.sh)
    # would wrongly collect trigger-paths for them. Neither has a suite.
    for f in bin/dispatch-evidence.sh bin/dispatch-evidence-for-tuple.sh; do
        out=$(map_to_test "$f")
        assert_empty "$out" "$f is not an evidence-run.yml script and must map to nothing"
    done
}

# The -f guard: with no trigger-paths suite present, an evidence lib maps to
# only the suites that exist (nothing, or its own suite), never to a missing
# path, and the guard does not cut the own-suite lookup short.
test_evidence_scripts_trigger_paths_guarded() {
    local root out
    if ! _load_map_to_test; then
        fail_test "could not extract map_to_test from $RUNNER"
        return 0
    fi
    root=$(/usr/bin/mktemp -d)
    /usr/bin/mkdir -p "$root/tests/unit" "$root/bin/lib"

    out=$(PROJECT_ROOT="$root" TESTS_DIR="$root/tests" map_to_test "bin/lib/evidence-x.sh")
    assert_empty "$out" "no trigger-paths suite must map to no test path"

    /usr/bin/touch "$root/tests/unit/evidence-run-trigger-paths.sh"
    out=$(PROJECT_ROOT="$root" TESTS_DIR="$root/tests" map_to_test "bin/lib/evidence-x.sh")
    assert_equals "$root/tests/unit/evidence-run-trigger-paths.sh" "$out" \
        "a present trigger-paths suite must be the evidence lib's selection"

    # A missing trigger-paths suite must not cut the own-suite lookup short.
    /usr/bin/rm -f "$root/tests/unit/evidence-run-trigger-paths.sh"
    /usr/bin/mkdir -p "$root/tests/unit/bin/lib"
    /usr/bin/touch "$root/tests/unit/bin/lib/evidence-x.sh"
    out=$(PROJECT_ROOT="$root" TESTS_DIR="$root/tests" map_to_test "bin/lib/evidence-x.sh")
    assert_equals "$root/tests/unit/bin/lib/evidence-x.sh" "$out" \
        "with trigger-paths absent, an evidence lib must still map to its own suite"

    /usr/bin/touch "$root/tests/unit/evidence-run-trigger-paths.sh"
    out=$(PROJECT_ROOT="$root" TESTS_DIR="$root/tests" map_to_test "bin/lib/evidence-x.sh" | command sort)
    assert_equals "$root/tests/unit/bin/lib/evidence-x.sh
$root/tests/unit/evidence-run-trigger-paths.sh" "$out" \
        "with both present, an evidence lib must map to exactly both"

    /usr/bin/rm -rf "$root"
}

run_test test_evidence_run_mapping_emits_both_suites "evidence-run.yml maps to both evidence-run suites (#1467)"
run_test test_evidence_run_mapping_follows_glob "evidence-run.yml mapping follows the evidence-run-*.sh glob (#1467)"
run_test test_evidence_scripts_map_to_trigger_paths "evidence-run.yml bin scripts map to the trigger-paths suite (#1473)"
run_test test_evidence_scripts_trigger_paths_guarded "evidence script trigger-paths mapping is -f guarded (#1473)"

# Generate test report
generate_report
