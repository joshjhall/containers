#!/usr/bin/env bash
# Unit tests for the branch-protection required-context set (issue #904).
#
# Background: `main` requires the status checks listed in
# `.github/required-checks.txt` before a PR can merge. That protection exists to
# close the #854 window, where a PR showing ZERO checks — because GitHub's
# `pull_request` event delivery lagged by 13m46s against a 3–4s baseline — could
# be merged on the absence of evidence.
#
# This test guards the MIRROR-IMAGE failure. A required context that never
# reports blocks `main` indefinitely: nothing can merge, and the cause (a
# renamed job, a narrowed trigger, a new `paths:` filter) is invisible because
# the workflow file still looks perfectly healthy on its own terms.
#
# The distinction that makes this subtle:
#
#   - A job that RUNS and concludes `SKIPPED` DOES satisfy a required context.
#     That is the healthy steady state here — `test-pr.yml` gates per-feature
#     builds behind change detection, so most checks legitimately sit in the
#     skipping bucket.
#   - A job that is NEVER SCHEDULED (its whole workflow was filtered out)
#     reports nothing at all, and blocks forever.
#
# So a required context must belong to a job whose workflow is triggered on
# EVERY pull request to `main`, unconditionally. Each test below covers one
# distinct way that stops being true.
#
# Two later additions extend the same never-reports/false-reports theme past
# the manifest itself:
#
#   - #910: a `check-name:` literal is a third copy of a job name that nothing
#     kept in sync. Its drift symptom is an indefinite WAIT, not an error.
#   - #909: `PR Tier` reporting is necessary but not sufficient — it must also
#     report FAILURE when the tier certified nothing. That test extracts and
#     executes the shipped rollup logic.
#
# Scope: this parses workflow YAML only — it never calls the GitHub API, so it
# runs offline and under SKIP_NETWORK_TESTS=1. It therefore verifies the
# manifest against the workflows in this checkout, NOT against the live branch
# protection setting. Drift between the manifest and the live setting is caught
# by reading the endpoint back (see docs/troubleshooting/ci-cd-issues.md).
#
# Run via: ./tests/run_unit_tests.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/framework.sh
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "Branch protection required checks"

WORKFLOWS_DIR="$PROJECT_ROOT/.github/workflows"
MANIFEST="$PROJECT_ROOT/.github/required-checks.txt"

# The branch the protection applies to. A required context must report on every
# PR targeting this branch.
PROTECTED_BRANCH="main"

# Read the manifest: one context name per line, `#` comments and blanks
# stripped. Names may contain spaces ("Run Tests"), so callers MUST read this
# line-by-line and never word-split it.
read_manifest() {
    [ -f "$MANIFEST" ] || return 0
    /usr/bin/sed -E 's/[[:space:]]*#.*$//' "$MANIFEST" |
        /usr/bin/grep -vE '^[[:space:]]*$' |
        /usr/bin/sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

# Every workflow file, NUL-free one per line (no spaces in these filenames).
workflow_files() {
    /usr/bin/find "$WORKFLOWS_DIR" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) | /usr/bin/sort
}

# yq is the parser for the trigger-shape tests below. Regex cannot reliably tell
# a `paths:` under `pull_request:` from one under `push:`, and getting that
# backwards is exactly the silent-pass this file exists to prevent.
#
# Absence is fatal in CI and a skip locally: ci.yml installs yq explicitly, so
# a missing binary there means the install step regressed. A test that quietly
# skips in CI renders as a pass and guards nothing (#768).
require_yq() {
    if command -v yq >/dev/null 2>&1; then
        return 0
    fi
    if [ "${CI:-false}" = "true" ]; then
        assert_true false \
            "yq is required in CI — required-context checks cannot silently skip (see .github/workflows/ci.yml)"
    else
        skip_test "yq not available — skipping required-context workflow parsing"
    fi
    return 1
}

# Print `<workflow-file>` for every job in any workflow whose job `name:` equals
# $1 exactly. Emits nothing when unmatched; multiple lines when ambiguous.
workflows_defining_job_name() {
    local wanted="$1" file
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        # `.jobs[].name` over every job; select exact matches. `// ""` keeps
        # jobs with no explicit `name:` from becoming `null` and matching.
        if yq -r '.jobs[] | (.name // "") ' "$file" 2>/dev/null |
            /usr/bin/grep -qxF -- "$wanted"; then
            /usr/bin/printf '%s\n' "$file"
        fi
    done < <(workflow_files)
}

test_manifest_exists_and_is_populated() {
    assert_true [ -f "$MANIFEST" ] ".github/required-checks.txt must exist"

    local count
    count=$(read_manifest | /usr/bin/wc -l | /usr/bin/tr -d ' ')
    if [ "${count:-0}" -gt 0 ]; then
        assert_true true "manifest lists $count required context(s)"
    else
        assert_true false "manifest lists no required contexts — branch protection would gate on nothing"
    fi
}

# A context name is matched by GitHub against the job's rendered name. If the
# job is renamed or deleted, the context never reports and `main` locks up.
test_every_context_matches_exactly_one_job() {
    require_yq || return 0

    local violations=0 ctx matches count
    while IFS= read -r ctx; do
        [ -n "$ctx" ] || continue
        matches=$(workflows_defining_job_name "$ctx")
        count=$(/usr/bin/printf '%s' "$matches" | /usr/bin/grep -c . || true)
        if [ "$count" -eq 0 ]; then
            /usr/bin/echo "  no job named '$ctx' in any workflow — this context would never report"
            violations=$((violations + 1))
        elif [ "$count" -gt 1 ]; then
            /usr/bin/echo "  job name '$ctx' is ambiguous across workflows:"
            /usr/bin/printf '%s\n' "$matches" | /usr/bin/sed 's/^/    /'
            violations=$((violations + 1))
        fi
    done < <(read_manifest)

    if [ "$violations" -eq 0 ]; then
        assert_true true "every required context maps to exactly one job"
    else
        assert_true false "$violations required context(s) do not map to exactly one job (see above)"
    fi
}

# The job must live in a workflow triggered on pull_request against the
# protected branch. A trigger narrowed to other branches means no report.
test_context_workflows_trigger_on_pull_request_to_protected_branch() {
    require_yq || return 0

    local violations=0 ctx file branches
    while IFS= read -r ctx; do
        [ -n "$ctx" ] || continue
        file=$(workflows_defining_job_name "$ctx" | /usr/bin/head -1)
        [ -n "$file" ] || continue # unmatched names are the previous test's job

        # `on` is parsed by yq as the boolean key `true` in YAML 1.1, so query
        # both spellings rather than trusting either alone.
        if ! yq -r '((.on // .["on"]) // {}) | has("pull_request")' "$file" 2>/dev/null |
            /usr/bin/grep -qx 'true'; then
            /usr/bin/echo "  '$ctx' ($(/usr/bin/basename "$file")): workflow has no pull_request trigger"
            violations=$((violations + 1))
            continue
        fi

        # An absent `branches:` means all branches — that is fine. A present one
        # must include the protected branch.
        branches=$(yq -r '((.on // .["on"]).pull_request.branches // ["*ALL*"]) | .[]' "$file" 2>/dev/null || true)
        if ! /usr/bin/printf '%s\n' "$branches" | /usr/bin/grep -qxF -- '*ALL*'; then
            if ! /usr/bin/printf '%s\n' "$branches" | /usr/bin/grep -qxF -- "$PROTECTED_BRANCH"; then
                /usr/bin/echo "  '$ctx' ($(/usr/bin/basename "$file")): pull_request trigger excludes '$PROTECTED_BRANCH'"
                violations=$((violations + 1))
            fi
        fi
    done < <(read_manifest)

    if [ "$violations" -eq 0 ]; then
        assert_true true "every required context's workflow triggers on PRs to $PROTECTED_BRANCH"
    else
        assert_true false "$violations required context(s) not triggered on PRs to $PROTECTED_BRANCH (see above)"
    fi
}

# THE trap. A `paths:`/`paths-ignore:` filter on the pull_request trigger means
# the whole workflow is not scheduled for PRs that touch nothing matching — the
# context reports NOTHING, and `main` becomes unmergeable for those PRs. This
# is distinct from a job that runs and skips, which satisfies the context fine.
test_context_workflows_have_no_pull_request_path_filters() {
    require_yq || return 0

    local violations=0 ctx file filter
    while IFS= read -r ctx; do
        [ -n "$ctx" ] || continue
        file=$(workflows_defining_job_name "$ctx" | /usr/bin/head -1)
        [ -n "$file" ] || continue

        for filter in paths paths-ignore; do
            if yq -r "((.on // .[\"on\"]).pull_request // {}) | has(\"$filter\")" "$file" 2>/dev/null |
                /usr/bin/grep -qx 'true'; then
                /usr/bin/echo "  '$ctx' ($(/usr/bin/basename "$file")): pull_request has a '$filter' filter — the workflow can be skipped entirely, so this context would never report and would block $PROTECTED_BRANCH"
                violations=$((violations + 1))
            fi
        done
    done < <(read_manifest)

    if [ "$violations" -eq 0 ]; then
        assert_true true "no required context sits behind a pull_request path filter"
    else
        assert_true false "$violations required context(s) behind a path filter (see above)"
    fi
}

# A matrix-templated name (`Rust Tests (stibbons) — ${{ matrix.os }}`) renders
# to a different string per cell, so the literal is never a reportable context.
# Requiring one would block `main` forever while every cell passes.
test_context_names_are_not_templated() {
    local violations=0 ctx
    while IFS= read -r ctx; do
        [ -n "$ctx" ] || continue
        if /usr/bin/printf '%s\n' "$ctx" | /usr/bin/grep -qF '${{'; then
            /usr/bin/echo "  '$ctx' contains a \${{ }} expression — not a stable context name"
            violations=$((violations + 1))
        fi
    done < <(read_manifest)

    if [ "$violations" -eq 0 ]; then
        assert_true true "no required context name contains a template expression"
    else
        assert_true false "$violations required context name(s) are templated (see above)"
    fi
}

# A `check-name:` literal (wait-on-check-action) is a THIRD copy of a job name,
# alongside the job's own `name:` and the manifest. The tests above keep the
# manifest and the jobs in sync but never read these literals, so this copy
# could drift silently (#910).
#
# The drift is not a loud error: wait-on-check-action polls for its check-name
# until the job timeout, so a name that never appears is an indefinite WAIT.
# Renaming ci.yml's `test` job and updating the manifest (which the tests above
# would force) leaves auto-merge.yml waiting on a string nothing reports, and
# version-update PRs simply stop auto-merging with no failure anywhere.
#
# Asserting against real job names — rather than against the manifest — catches
# exactly that rename without coupling every future wait-on-check to the
# branch-protection required list, which is a separate decision.
test_check_name_literals_match_a_real_job() {
    require_yq || return 0

    local violations=0 checked=0 file literal matches count
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        # Recursive walk: `check-name:` sits inside a step's `with:` map at no
        # fixed depth, so match any map carrying the key rather than a path.
        while IFS= read -r literal; do
            [ -n "$literal" ] || continue
            checked=$((checked + 1))

            # A templated literal renders per-run and can't be matched against a
            # static job name — flag it rather than silently passing it through.
            if /usr/bin/printf '%s\n' "$literal" | /usr/bin/grep -qF '${{'; then
                /usr/bin/echo "  '$literal' ($(/usr/bin/basename "$file")): check-name contains a \${{ }} expression — cannot be verified against a job name"
                violations=$((violations + 1))
                continue
            fi

            matches=$(workflows_defining_job_name "$literal")
            count=$(/usr/bin/printf '%s' "$matches" | /usr/bin/grep -c . || true)
            if [ "$count" -eq 0 ]; then
                /usr/bin/echo "  '$literal' ($(/usr/bin/basename "$file")): no job with this name exists — wait-on-check-action would poll until timeout (a silent stall, not an error)"
                violations=$((violations + 1))
            elif [ "$count" -gt 1 ]; then
                /usr/bin/echo "  '$literal' ($(/usr/bin/basename "$file")): ambiguous across workflows:"
                /usr/bin/printf '%s\n' "$matches" | /usr/bin/sed 's/^/    /'
                violations=$((violations + 1))
            fi
        done < <(yq -r '[.. | select(type == "!!map" and has("check-name")) | .["check-name"]] | .[]' "$file" 2>/dev/null || true)
    done < <(workflow_files)

    if [ "$violations" -eq 0 ]; then
        assert_true true "all $checked check-name literal(s) resolve to exactly one job"
    else
        assert_true false "$violations check-name literal(s) do not map to exactly one job (see above)"
    fi
}

# --- pr-tier rollup behavior (#909) ----------------------------------------
#
# `PR Tier` is a manifest entry, so its verdict is what branch protection acts
# on. The tests above prove it REPORTS; these prove it reports the right thing.
#
# The bug this covers: the rollup read `needs.build-feature.result` without
# consulting `needs.detect-changes.result`. A failed detect-changes leaves MODE
# empty (its compute step never wrote outputs) and build-feature `skipped` (by
# needs-failure propagation, not `failure`) — so the rollup exited 0 having
# certified a PR where nothing was built or smoke-tested.
#
# We extract and EXECUTE the shipped run block rather than re-describing it, so
# the test cannot pass against a transcription that has drifted from the
# workflow. Same approach as tests/unit/evidence-verdict.sh.
PR_TIER_WORKFLOW="$WORKFLOWS_DIR/test-pr.yml"

# Extract pr-tier's Summarize step into $1 and echo nothing. Returns non-zero
# if the step cannot be found, so a restructured job fails loudly here rather
# than silently testing an empty script.
extract_pr_tier_script() {
    local dest="$1"
    yq -r '.jobs["pr-tier"].steps[] | select(.name == "Summarize") | .run' \
        "$PR_TIER_WORKFLOW" 2>/dev/null >"$dest" || return 1
    [ -s "$dest" ] || return 1
    # `null` is what yq prints when the select matched nothing.
    ! /usr/bin/grep -qx 'null' "$dest" || return 1
}

# Run the extracted rollup under one (DETECT_RESULT, MODE, BUILD_RESULT) triple
# and echo its exit code. Never lets a non-zero exit abort the suite.
run_pr_tier() {
    local script="$1" detect="$2" mode="$3" build="$4" rc=0
    DETECT_RESULT="$detect" MODE="$mode" BUILD_RESULT="$build" \
        bash "$script" >/dev/null 2>&1 || rc=$?
    /usr/bin/printf '%s\n' "$rc"
}

test_pr_tier_verdict_matrix() {
    require_yq || return 0

    local script="$TEST_TEMP_DIR/pr-tier.sh"
    if ! extract_pr_tier_script "$script"; then
        assert_true false "could not extract pr-tier's 'Summarize' step from test-pr.yml — the job was renamed or restructured"
        return 0
    fi

    # Each row is: detect-changes result | mode | build-feature result | expected exit.
    #
    # The first two rows are the #909 bug (both exited 0 before the fix). The
    # last three are what keeps the assertion honest: a guard that simply
    # failed everything would pass rows 1-2 while breaking every real PR, so
    # the passing rows are as load-bearing as the failing ones.
    #
    # MODE is empty on the failure rows on purpose — that is the real shape,
    # since detect-changes' compute step never reaches its `echo mode=...`.
    local -a cases=(
        "failure||skipped|1|a failed detect-changes fails the rollup"
        "cancelled||skipped|1|a cancelled detect-changes fails the rollup"
        "success|skip|skipped|0|a genuine skip (docs-only PR) still passes"
        "success|changed|success|0|all matrix cells passing still passes"
        "success|changed|failure|1|a real build failure still fails"
    )

    local row detect mode build expected desc rc violations=0
    for row in "${cases[@]}"; do
        IFS='|' read -r detect mode build expected desc <<<"$row"
        rc=$(run_pr_tier "$script" "$detect" "$mode" "$build")
        if [ "$rc" != "$expected" ]; then
            /usr/bin/echo "  detect=${detect} mode=${mode:-<empty>} build=${build}: expected exit ${expected}, got ${rc} — ${desc}"
            violations=$((violations + 1))
        fi
    done

    if [ "$violations" -eq 0 ]; then
        assert_true true "pr-tier's verdict is correct across all ${#cases[@]} upstream states"
    else
        assert_true false "$violations pr-tier state(s) produced the wrong verdict (see above)"
    fi
}

run_test test_manifest_exists_and_is_populated "manifest exists and lists contexts"
run_test test_every_context_matches_exactly_one_job "each context maps to exactly one job"
run_test test_context_workflows_trigger_on_pull_request_to_protected_branch "each context's workflow triggers on PRs to $PROTECTED_BRANCH"
run_test test_context_workflows_have_no_pull_request_path_filters "no context sits behind a pull_request path filter"
run_test test_context_names_are_not_templated "context names are not templated"
run_test test_check_name_literals_match_a_real_job "each check-name literal maps to exactly one job"
run_test test_pr_tier_verdict_matrix "pr-tier's verdict is correct across upstream states"

generate_report
