#!/usr/bin/env bash
# Unit tests: every integration suite has a recorded CI disposition (issue #1027).
#
# Background: all 20 suites in tests/integration/builds/ declared
# `# @tier: merge,weekly`, but no workflow selects suites by tier — the merge
# tier runs exactly the suites named in ci.yml's `integration-test` matrix. So
# 16 of them ran in no CI tier at all, and test_bindfs.sh rotted unnoticed
# (#108 moved the logic it grepped for). A suite that never executes reports
# nothing, and nothing reads as green.
#
# The contract checked here, in both directions:
#   - a suite named in the matrix (`test` or space-separated `extra_suites`)
#     declares `merge` in its @tier header and carries no `# @ci:` marker;
#   - any other suite carries `# @ci: <scheduled|local-only> — <reason>` and
#     does NOT declare `merge` — including by omission, since a suite with no
#     @tier header defaults to merge (test_in_tier in run_integration_tests.sh);
#   - every suite the matrix names exists, and reads IMAGE_TO_TEST (so it tests
#     the published image rather than building its own inside the job);
#   - when any variant uses `extra_suites`, a gating step actually executes
#     them (calls the runner, passes IMAGE_TO_TEST_MINIMAL, no
#     continue-on-error or `|| true`) — a listed-but-unrun rider is the
#     original rot one level down — and every rider expands
#     IMAGE_TO_TEST_MINIMAL, so the step's minimal image is actually used.
#
# The checker runs against fixtures as well as the real tree, so each rule is
# shown to FAIL on the defect it exists for.
#
# Scope: parses YAML and shell headers only — offline, safe under
# SKIP_NETWORK_TESTS=1.
#
# Run via: ./tests/run_unit_tests.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/framework.sh
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "Integration suite CI coverage"

if ! command -v yq >/dev/null 2>&1; then
    echo "SKIP: yq not available — install yq to run integration-ci-coverage tests"
    exit 0
fi

CI_WORKFLOW="$PROJECT_ROOT/.github/workflows/ci.yml"
BUILDS_DIR="$PROJECT_ROOT/tests/integration/builds"

# matrix_suites CI_FILE — prints each suite the integration-test matrix runs,
# one per line.
matrix_suites() {
    yq -r '
        .jobs["integration-test"].strategy.matrix.variant // [] | .[]
        | ((.test // "") + " " + (.extra_suites // ""))
    ' "$1" | command tr ' ' '\n' | command sed '/^$/d' | command sort -u
}

# declared_tiers FILE — the @tier list exactly as run_integration_tests.sh's
# test_in_tier reads it (absent header → merge), one tier per line. Strip only
# [:blank:]: [:space:] includes the newlines `tr ',' '\n'` just produced and
# collapses `merge,weekly` to `mergeweekly` (the bug fixed in #1027).
declared_tiers() {
    local declared
    declared=$(command grep -m1 -oE '^#[[:space:]]*@tier:[[:space:]]*[a-z,[:space:]]+' "$1" 2>/dev/null |
        command sed -E 's/^#[[:space:]]*@tier:[[:space:]]*//' || true)
    [ -z "$declared" ] && declared="merge"
    command echo "$declared" | command tr ',' '\n' | command tr -d '[:blank:]' | command sed '/^$/d'
}

# coverage_violations CI_FILE BUILDS_DIR — prints "suite: problem" per breach.
coverage_violations() {
    local ci_file="$1" builds_dir="$2"
    local in_ci file suite tiers marker
    in_ci=$(matrix_suites "$ci_file")

    while IFS= read -r suite; do
        [ -f "$builds_dir/test_${suite}.sh" ] ||
            command echo "$suite: named in the CI matrix but test_${suite}.sh does not exist"
    done <<<"$in_ci"

    for file in "$builds_dir"/test_*.sh; do
        [ -f "$file" ] || continue
        suite=$(command basename "$file" .sh)
        suite="${suite#test_}"
        tiers=$(declared_tiers "$file")
        marker=$(command grep -m1 -E '^#[[:space:]]*@ci:' "$file" || true)

        if command grep -Fxq "$suite" <<<"$in_ci"; then
            command grep -Fxq merge <<<"$tiers" ||
                command echo "$suite: runs in the merge tier but @tier omits merge"
            [ -z "$marker" ] ||
                command echo "$suite: runs in the merge tier but carries an @ci: marker"
        else
            if ! command grep -qE '^#[[:space:]]*@ci:[[:space:]]*(scheduled|local-only)[[:space:]]+—[[:space:]]*[^[:space:]]' <<<"$marker"; then
                command echo "$suite: in no CI matrix and has no '# @ci: <scheduled|local-only> — <reason>' marker"
            fi
            if command grep -Fxq merge <<<"$tiers"; then
                command echo "$suite: claims the merge tier (@tier, or no header) but no CI matrix runs it"
            fi
        fi
    done
}

# make_fixture DIR — a CI file running `covered` (+ extra `rider`), and a
# builds dir to populate per test.
make_fixture() {
    local dir="$1"
    command mkdir -p "$dir/builds"
    command cat >"$dir/ci.yml" <<'EOF'
jobs:
  integration-test:
    strategy:
      matrix:
        variant:
          - name: a
            test: covered
            extra_suites: rider
EOF
    printf '#!/usr/bin/env bash\n# @tier: merge,weekly\n' >"$dir/builds/test_covered.sh"
    printf '#!/usr/bin/env bash\n# @tier: merge\n' >"$dir/builds/test_rider.sh"
}

# extra_suites_step_problems CI_FILE — prints one line per way the
# integration-test job fails to actually EXECUTE its `extra_suites` entries.
# Without a consuming step, a suite listed in extra_suites satisfies every
# header check above while never running — the rot #1027 exists to end.
extra_suites_step_problems() {
    local ci_file="$1" uses_extra consumers
    uses_extra=$(yq -r '[.jobs["integration-test"].strategy.matrix.variant // [] | .[] | select(.extra_suites)] | length' "$ci_file")
    [ "$uses_extra" = "0" ] && return 0

    # A consuming step reads matrix.variant.extra_suites (via env: or run:).
    consumers=$(yq -r '
        .jobs["integration-test"].steps // [] | .[]
        | select(((.env // {}) | to_entries | map(.value) | join(" ") | test("matrix\\.variant\\.extra_suites"))
              or ((.run // "") | test("matrix\\.variant\\.extra_suites")))
        | [((.run // "") | test("run_integration_tests\\.sh")),
           ((.run // "") | test("IMAGE_TO_TEST_MINIMAL=")),
           ((.["continue-on-error"] // false) | tostring),
           ((.run // "") | test("\\|\\|[[:space:]]*true"))]
        | @tsv' "$ci_file")
    if [ -z "$consumers" ]; then
        command echo "no integration-test step consumes matrix.variant.extra_suites"
        return 0
    fi
    local runs minimal coe swallow
    while IFS=$'\t' read -r runs minimal coe swallow; do
        [ "$runs" = "true" ] || command echo "extra_suites step never calls run_integration_tests.sh"
        [ "$minimal" = "true" ] || command echo "extra_suites step does not pass IMAGE_TO_TEST_MINIMAL"
        [ "$coe" = "false" ] || command echo "extra_suites step sets continue-on-error"
        [ "$swallow" = "false" ] || command echo "extra_suites step swallows failures with || true"
    done <<<"$consumers"
}

# ---------------------------------------------------------------------------
# Checker self-tests on fixtures (prove each rule can fail)
# ---------------------------------------------------------------------------

test_checker_passes_clean_fixture() {
    local dir got
    dir=$(command mktemp -d)
    make_fixture "$dir"
    printf '#!/usr/bin/env bash\n# @tier: weekly\n# @ci: local-only — needs a socket\n' \
        >"$dir/builds/test_parked.sh"
    got=$(coverage_violations "$dir/ci.yml" "$dir/builds")
    command rm -rf "$dir"
    assert_equals "" "$got" "a matrix suite, an extra_suites rider and a marked suite all pass"
}

test_checker_flags_unmarked_suite() {
    local dir got
    dir=$(command mktemp -d)
    make_fixture "$dir"
    printf '#!/usr/bin/env bash\n# @tier: weekly\n' >"$dir/builds/test_orphan.sh"
    got=$(coverage_violations "$dir/ci.yml" "$dir/builds")
    command rm -rf "$dir"
    assert_contains "$got" "orphan: in no CI matrix and has no" "an uncovered suite without @ci: is flagged"
}

test_checker_flags_headerless_suite() {
    # No @tier header defaults to merge — the shape a brand-new suite takes.
    local dir got
    dir=$(command mktemp -d)
    make_fixture "$dir"
    printf '#!/usr/bin/env bash\n# @ci: scheduled — heavy build\n' >"$dir/builds/test_fresh.sh"
    got=$(coverage_violations "$dir/ci.yml" "$dir/builds")
    command rm -rf "$dir"
    assert_contains "$got" "fresh: claims the merge tier" "a header-less uncovered suite is flagged"
}

test_checker_flags_reasonless_marker() {
    local dir got
    dir=$(command mktemp -d)
    make_fixture "$dir"
    printf '#!/usr/bin/env bash\n# @tier: weekly\n# @ci: scheduled\n' >"$dir/builds/test_vague.sh"
    got=$(coverage_violations "$dir/ci.yml" "$dir/builds")
    command rm -rf "$dir"
    assert_contains "$got" "vague: in no CI matrix" "an @ci: marker with no reason is flagged"
}

test_checker_flags_matrix_suite_drift() {
    local dir got
    dir=$(command mktemp -d)
    make_fixture "$dir"
    printf '#!/usr/bin/env bash\n# @tier: weekly\n# @ci: scheduled — stale\n' >"$dir/builds/test_rider.sh"
    got=$(coverage_violations "$dir/ci.yml" "$dir/builds")
    command rm -rf "$dir"
    assert_contains "$got" "rider: runs in the merge tier but @tier omits merge" \
        "an extra_suites rider without merge is flagged"
    assert_contains "$got" "rider: runs in the merge tier but carries an @ci: marker" \
        "an extra_suites rider with a stale @ci: marker is flagged"
}

test_checker_flags_missing_matrix_suite() {
    local dir got
    dir=$(command mktemp -d)
    make_fixture "$dir"
    command rm "$dir/builds/test_rider.sh"
    got=$(coverage_violations "$dir/ci.yml" "$dir/builds")
    command rm -rf "$dir"
    assert_contains "$got" "rider: named in the CI matrix but test_rider.sh does not exist" \
        "a matrix suite with no file is flagged"
}

test_runner_tier_filter_splits_multi_tier_header() {
    # Run the runner's own test_in_tier, extracted from the script, so the
    # header parsing this guard mirrors cannot silently diverge from it.
    local dir fn
    dir=$(command mktemp -d)
    printf '#!/usr/bin/env bash\n# @tier: pr, merge,weekly\n' >"$dir/test_x.sh"
    printf '#!/usr/bin/env bash\n# no tier header\n' >"$dir/test_bare.sh"
    fn=$(command sed -n '/^test_in_tier() {/,/^}/p' "$PROJECT_ROOT/tests/run_integration_tests.sh")
    if [ -z "$fn" ]; then
        command rm -rf "$dir"
        assert_true false "test_in_tier not found in run_integration_tests.sh"
        return
    fi
    eval "$fn"
    local f t runner mine mismatch=""
    for f in "$dir/test_x.sh" "$dir/test_bare.sh"; do
        runner="" mine=""
        for t in pr merge weekly monthly; do
            test_in_tier "$f" "$t" && runner+="$t "
        done
        # The guard's own parser must agree with the runner, file by file.
        mine=$(declared_tiers "$f" | command tr '\n' ' ')
        [ "$runner" = "$mine" ] || mismatch+="$(command basename "$f"): runner='$runner' guard='$mine' "
        case "$f" in
            */test_x.sh) assert_equals "pr merge weekly " "$runner" \
                "--tier matches each tier of a comma-separated header" ;;
            */test_bare.sh) assert_equals "merge " "$runner" \
                "a header-less suite defaults to the merge tier only" ;;
        esac
    done
    command rm -rf "$dir"
    assert_equals "" "$mismatch" "declared_tiers agrees with the runner's test_in_tier"
}

# matrix_suites_ignoring_image CI_FILE BUILDS_DIR — prints each matrix suite
# whose file never EXPANDS $IMAGE_TO_TEST on a non-comment line. Such a suite
# would silently build its own image inside the merge-tier job instead of
# testing the published one; a mention in a comment does not count.
matrix_suites_ignoring_image() {
    local suite
    while IFS= read -r suite; do
        [ -f "$2/test_${suite}.sh" ] || continue
        command grep -vE '^[[:space:]]*#' "$2/test_${suite}.sh" |
            command grep -qE '\$\{?IMAGE_TO_TEST' || command echo "$suite"
    done < <(matrix_suites "$1")
}

# extra_suites_ignoring_minimal CI_FILE BUILDS_DIR — prints each `extra_suites`
# rider whose file never expands $IMAGE_TO_TEST_MINIMAL on a non-comment line.
# The extra_suites step hands every rider the published minimal image so a
# flag-absent check (bindfs's test_no_bindfs_without_flag) needs no local
# build; a rider that stops reading it silently brings that full build back
# inside the merge-tier job's 30-minute budget.
extra_suites_ignoring_minimal() {
    local suite
    while IFS= read -r suite; do
        [ -f "$2/test_${suite}.sh" ] || continue
        command grep -vE '^[[:space:]]*#' "$2/test_${suite}.sh" |
            command grep -qE '\$\{?IMAGE_TO_TEST_MINIMAL' || command echo "$suite"
    done < <(yq -r '.jobs["integration-test"].strategy.matrix.variant // [] | .[] | .extra_suites // ""' "$1" |
        command tr ' ' '\n' | command sed '/^$/d' | command sort -u)
}

test_checker_flags_suite_ignoring_image() {
    local dir got
    dir=$(command mktemp -d)
    make_fixture "$dir"
    printf 'image="${IMAGE_TO_TEST:-local}"\n' >>"$dir/builds/test_covered.sh"
    # A comment-only mention must not satisfy the check.
    printf '# honors IMAGE_TO_TEST (it does not)\n' >>"$dir/builds/test_rider.sh"
    got=$(matrix_suites_ignoring_image "$dir/ci.yml" "$dir/builds")
    command rm -rf "$dir"
    assert_equals "rider" "$got" \
        "a matrix suite that never expands IMAGE_TO_TEST (comment-only mention) is flagged"
}

test_extra_suites_step_gates() {
    local got
    got=$(extra_suites_step_problems "$CI_WORKFLOW")
    assert_equals "" "$got" "integration-test executes its extra_suites and gates on them"
}

test_extra_suites_use_published_minimal() {
    local got
    got=$(extra_suites_ignoring_minimal "$CI_WORKFLOW" "$BUILDS_DIR")
    assert_equals "" "$got" "every extra_suites rider honors IMAGE_TO_TEST_MINIMAL"
}

test_matrix_suites_test_published_image() {
    local got
    got=$(matrix_suites_ignoring_image "$CI_WORKFLOW" "$BUILDS_DIR")
    assert_equals "" "$got" "every merge-tier suite honors IMAGE_TO_TEST"
}

test_checker_flags_rider_ignoring_minimal() {
    local dir got
    dir=$(command mktemp -d)
    make_fixture "$dir"
    # `covered` is a plain matrix test, not a rider: it needs no minimal image.
    printf '# reads IMAGE_TO_TEST_MINIMAL (it does not)\n' >>"$dir/builds/test_rider.sh"
    got=$(extra_suites_ignoring_minimal "$dir/ci.yml" "$dir/builds")
    printf 'image="${IMAGE_TO_TEST_MINIMAL:-x}"\n' >>"$dir/builds/test_rider.sh"
    got+="|$(extra_suites_ignoring_minimal "$dir/ci.yml" "$dir/builds")"
    command rm -rf "$dir"
    assert_equals "rider|" "$got" \
        "a rider that never expands IMAGE_TO_TEST_MINIMAL is flagged; one that does passes"
}

test_checker_flags_missing_extra_suites_step() {
    local dir got
    dir=$(command mktemp -d)
    make_fixture "$dir"
    got=$(extra_suites_step_problems "$dir/ci.yml")
    command rm -rf "$dir"
    assert_equals "no integration-test step consumes matrix.variant.extra_suites" "$got" \
        "extra_suites with no consuming step is flagged"
}

test_checker_flags_weak_extra_suites_step() {
    local dir got
    dir=$(command mktemp -d)
    make_fixture "$dir"
    command cat >>"$dir/ci.yml" <<'YAML'
    steps:
      - name: extras
        continue-on-error: true
        env:
          EXTRA_SUITES: ${{ matrix.variant.extra_suites }}
        run: |
          for s in $EXTRA_SUITES; do printf '%s\n' "$s" || true; done
YAML
    got=$(extra_suites_step_problems "$dir/ci.yml")
    command rm -rf "$dir"
    assert_contains "$got" "never calls run_integration_tests.sh" "a step that runs nothing is flagged"
    assert_contains "$got" "does not pass IMAGE_TO_TEST_MINIMAL" "a step without the minimal image is flagged"
    assert_contains "$got" "sets continue-on-error" "a non-gating step is flagged"
    assert_contains "$got" "swallows failures" "a || true step is flagged"
}

# ---------------------------------------------------------------------------
# The real tree
# ---------------------------------------------------------------------------

test_real_matrix_is_parsed() {
    # An empty parse (renamed job, moved matrix) would make every suite read as
    # uncovered-but-marked and the tree check below vacuous.
    local suites
    suites=$(matrix_suites "$CI_WORKFLOW")
    assert_contains "$suites" "minimal" "integration-test matrix parses (minimal)"
    assert_contains "$suites" "bindfs" "integration-test matrix runs bindfs via extra_suites"
}

test_every_suite_has_ci_disposition() {
    local count got
    count=$(command find "$BUILDS_DIR" -name 'test_*.sh' -type f | command wc -l)
    got=$(coverage_violations "$CI_WORKFLOW" "$BUILDS_DIR")
    if [ "$count" -eq 0 ]; then
        assert_true false "no integration suites found under $BUILDS_DIR"
    elif [ -n "$got" ]; then
        command echo "$got" | command sed 's/^/    /'
        assert_true false "every integration suite runs in CI or records why not"
    else
        assert_true true "all $count integration suites have a CI disposition"
    fi
}

run_test test_checker_passes_clean_fixture "Checker passes a consistent fixture"
run_test test_checker_flags_unmarked_suite "Checker flags an uncovered suite without @ci:"
run_test test_checker_flags_headerless_suite "Checker flags a header-less uncovered suite"
run_test test_checker_flags_reasonless_marker "Checker flags an @ci: marker with no reason"
run_test test_checker_flags_matrix_suite_drift "Checker flags a matrix suite with drifted headers"
run_test test_checker_flags_missing_matrix_suite "Checker flags a matrix suite with no file"
run_test test_runner_tier_filter_splits_multi_tier_header "Runner --tier filter splits multi-tier headers"
run_test test_checker_flags_suite_ignoring_image "Checker flags a matrix suite ignoring IMAGE_TO_TEST"
run_test test_checker_flags_rider_ignoring_minimal "Checker flags a rider ignoring IMAGE_TO_TEST_MINIMAL"
run_test test_checker_flags_missing_extra_suites_step "Checker flags extra_suites with no consuming step"
run_test test_checker_flags_weak_extra_suites_step "Checker flags a non-gating extra_suites step"
run_test test_real_matrix_is_parsed "Real integration-test matrix parses"
run_test test_every_suite_has_ci_disposition "Every integration suite has a CI disposition"
run_test test_matrix_suites_test_published_image "Every merge-tier suite honors IMAGE_TO_TEST"
run_test test_extra_suites_step_gates "The extra_suites step runs and gates the job"
run_test test_extra_suites_use_published_minimal "Every extra_suites rider honors IMAGE_TO_TEST_MINIMAL"

generate_report
