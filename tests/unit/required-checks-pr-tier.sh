#!/usr/bin/env bash
# Unit tests for the `PR Tier` rollup in .github/workflows/test-pr.yml.
#
# `PR Tier` is a required context on `main` (#904; tests/unit/required-checks.sh
# proves it always REPORTS). This suite proves it reports the RIGHT verdict:
#
#   - #909: FAILURE when the tier certified nothing (a failed or cancelled
#     detect-changes), not a green on no evidence.
#   - #1099: on an irrelevant-label run, MIRROR the newest other non-cancelled
#     `PR Tier` verdict on the SHA, failing closed on anything but a completed
#     pass — and the trigger/concurrency/permission shape that mirror needs.
#
# Both extract and EXECUTE the shipped Summarize run block rather than
# re-describing it. `gh` is stubbed; nothing here touches the network.
#
# Split out of required-checks.sh in issue #1271.
#
# Run via: ./tests/run_unit_tests.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/framework.sh
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "PR Tier rollup verdict"

WORKFLOWS_DIR="$PROJECT_ROOT/.github/workflows"

# shellcheck source=tests/framework/helpers/required-checks.sh
source "$SCRIPT_DIR/../framework/helpers/required-checks.sh"

# --- pr-tier rollup behavior (#909) ----------------------------------------
#
# `PR Tier` is a manifest entry, so its verdict is what branch protection acts
# on. tests/unit/required-checks.sh proves it REPORTS; these prove it reports
# the right thing.
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
#
# Overridable so a mutation check can point the suite at a scratch copy of the
# workflow; never mutate the tracked file to prove a row bites.
PR_TIER_WORKFLOW="${PR_TIER_WORKFLOW:-$WORKFLOWS_DIR/test-pr.yml}"

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
#
# The event env is a plain push (`synchronize`): on a real runner these are
# always set, and the run block reads them under `set -u`. Label events are
# covered by run_pr_tier_mirror below (#1099).
run_pr_tier() {
    local script="$1" detect="$2" mode="$3" build="$4" rc=0
    DETECT_RESULT="$detect" MODE="$mode" BUILD_RESULT="$build" \
        EVENT_ACTION="synchronize" EVENT_LABEL="" \
        REPO="owner/repo" HEAD_SHA="deadbeef" RUN_ID="200" \
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
    # rest are what keeps the assertion honest: a guard that simply failed
    # everything would pass rows 1-2 while breaking every real PR, so the
    # passing rows are as load-bearing as the failing ones.
    #
    # MODE is empty on the failure rows on purpose — that is the real shape,
    # since detect-changes' compute step never reaches its `echo mode=...`.
    #
    # The LAST row is the one that is easy to leave out and costly to miss: a
    # non-`skip` mode whose matrix came out empty, so BUILD_RESULT is `skipped`
    # on a path that does NOT short-circuit in the `case` above. It is the only
    # row that reaches the BUILD_RESULT check with `skipped`, and therefore the
    # only one covering the branch the job's comment describes. Without it,
    # tightening that check to accept `success` alone would break real PRs
    # while this test still passed.
    local -a cases=(
        "failure||skipped|1|a failed detect-changes fails the rollup"
        "cancelled||skipped|1|a cancelled detect-changes fails the rollup"
        "success|skip|skipped|0|a genuine skip (docs-only PR) still passes"
        "success|changed|success|0|all matrix cells passing still passes"
        "success|changed|failure|1|a real build failure still fails"
        "success|changed|skipped|0|a non-skip mode with an empty matrix still passes"
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

# --- irrelevant-label mirror (#1099) ----------------------------------------
#
# `labeled` is in the trigger, so every label add creates a run. A run for a
# label other than `ci/full-build` skips detect-changes and build-feature,
# and pr-tier then MIRRORS the newest other non-cancelled `PR Tier` check
# run on the SHA. Reporting skipped/green instead would make that run the
# newest `PR Tier` and mask an earlier failed build (the #854/#909 class).
#
# `gh` is stubbed on PATH. The stub answers in the shape `gh api --jq
# '.check_runs[]'` really produces: one compact JSON object per line, not
# the raw response envelope. BASH_ENV is cleared so /etc/bash_env cannot
# rebuild PATH around the stub (#618).

# Write a `gh` stub into $1 that prints $2 (fixture lines) and exits $3,
# recording every call in $1/gh.calls — one argv element per line, then a
# `---` terminator per call. Per-element recording is what lets the query
# check pin whole arguments: a flattened "$*" log lets `filter=all` match
# anywhere in any argument (#1271).
write_gh_stub() {
    local dir="$1" fixture="$2" rc="$3"
    /usr/bin/mkdir -p "$dir"
    /usr/bin/printf '%s\n' "$fixture" >"$dir/fixture"
    /usr/bin/cat >"$dir/gh" <<EOF
#!/usr/bin/env bash
/usr/bin/printf '%s\n' "\$@" --- >>"$dir/gh.calls"
[ "$rc" = 0 ] || exit $rc
/usr/bin/cat "$dir/fixture"
EOF
    /usr/bin/chmod +x "$dir/gh"
}

# Run the extracted rollup $1 as a `labeled` run for label $3 (default: an
# irrelevant one) against the gh stub dir $2. Echoes the exit code.
run_pr_tier_mirror() {
    local script="$1" stub="$2" label="${3:-status/pr-pending}" rc=0
    BASH_ENV="" PATH="$stub:$PATH" \
        DETECT_RESULT="skipped" MODE="" BUILD_RESULT="skipped" \
        EVENT_ACTION="labeled" EVENT_LABEL="$label" \
        REPO="owner/repo" HEAD_SHA="deadbeef" RUN_ID="200" \
        bash "$script" >/dev/null 2>&1 || rc=$?
    /usr/bin/printf '%s\n' "$rc"
}

test_pr_tier_mirror_verdict() {
    require_yq || return 0
    command -v jq >/dev/null 2>&1 || {
        skip_test "jq not available — skipping pr-tier mirror tests"
        return 0
    }

    local script="$TEST_TEMP_DIR/pr-tier.sh"
    if ! extract_pr_tier_script "$script"; then
        assert_true false "could not extract pr-tier's 'Summarize' step from test-pr.yml — the job was renamed or restructured"
        return 0
    fi

    # Check-run fixtures. RUN_ID is 200, so a details_url under
    # /actions/runs/200/ is this run's own check run and must be ignored.
    local own='{"id":30,"status":"in_progress","conclusion":null,"details_url":"https://github.com/owner/repo/actions/runs/200/job/3"}'
    local ok='{"id":10,"status":"completed","conclusion":"success","details_url":"https://github.com/owner/repo/actions/runs/100/job/1"}'
    local bad='{"id":20,"status":"completed","conclusion":"failure","details_url":"https://github.com/owner/repo/actions/runs/150/job/2"}'
    local cancelled='{"id":25,"status":"completed","conclusion":"cancelled","details_url":"https://github.com/owner/repo/actions/runs/160/job/4"}'
    local running='{"id":25,"status":"in_progress","conclusion":null,"details_url":"https://github.com/owner/repo/actions/runs/160/job/4"}'
    local ok_new='{"id":40,"status":"completed","conclusion":"success","details_url":"https://github.com/owner/repo/actions/runs/170/job/5"}'
    local skipped='{"id":40,"status":"completed","conclusion":"skipped","details_url":"https://github.com/owner/repo/actions/runs/170/job/5"}'
    local neutral='{"id":40,"status":"completed","conclusion":"neutral","details_url":"https://github.com/owner/repo/actions/runs/170/job/5"}'
    local timed_out='{"id":40,"status":"completed","conclusion":"timed_out","details_url":"https://github.com/owner/repo/actions/runs/170/job/5"}'
    # #1271 gaps. Each is the NEWEST run, paired with an older verdict of the
    # opposite polarity, so a mutant of the branch it probes flips the exit:
    #   - queued: a filter that kept only completed runs would fall back to $ok.
    #   - null / absent details_url: without the `// ""` default, jq errors on
    #     `null | contains(...)` and the mirror fails closed instead of passing.
    #   - action_required / stale: widening the pass list, or excluding these
    #     like `cancelled`, would mirror $ok instead of failing.
    local queued='{"id":40,"status":"queued","conclusion":null,"details_url":"https://github.com/owner/repo/actions/runs/170/job/5"}'
    local ok_null_url='{"id":40,"status":"completed","conclusion":"success","details_url":null}'
    local ok_no_url='{"id":40,"status":"completed","conclusion":"success"}'
    local action_required='{"id":40,"status":"completed","conclusion":"action_required","details_url":"https://github.com/owner/repo/actions/runs/170/job/5"}'
    local stale='{"id":40,"status":"completed","conclusion":"stale","details_url":"https://github.com/owner/repo/actions/runs/170/job/5"}'

    # Each row: fixture lines | gh exit | expected exit | description.
    # "Newest" is the highest id, NOT the last line: the API's order is not
    # guaranteed, so the newest-wins rows appear in both line orders. A mirror
    # that took "any success", the first line, or the last line (no sort)
    # fails at least one of them.
    local -a cases=(
        "$ok"$'\n'"$own|0|0|newest other run succeeded → mirror passes"
        "$ok"$'\n'"$bad"$'\n'"$own|0|1|newest other run failed → mirror fails (no masking)"
        "$bad"$'\n'"$ok"$'\n'"$own|0|1|newest failure listed first still wins over an older success"
        "$ok_new"$'\n'"$bad"$'\n'"$own|0|0|newest success listed first still wins over an older failure"
        "$bad"$'\n'"$skipped"$'\n'"$own|0|0|a newest skipped verdict (docs-only push) passes"
        "$bad"$'\n'"$neutral"$'\n'"$own|0|0|a newest neutral verdict passes"
        "$ok"$'\n'"$timed_out"$'\n'"$own|0|1|a newest timed_out verdict fails"
        "not json|0|1|an unparsable gh response → fail closed"
        "$bad"$'\n'"$cancelled"$'\n'"$own|0|1|a cancelled newer run does not hide a failure"
        "$ok"$'\n'"$cancelled"$'\n'"$own|0|0|a cancelled newest run falls back to the older success"
        "$ok"$'\n'"$running"$'\n'"$own|0|1|newest other run still in progress → fail closed"
        "$ok"$'\n'"$queued"$'\n'"$own|0|1|newest other run still queued → fail closed"
        "$bad"$'\n'"$ok_null_url"$'\n'"$own|0|0|a null details_url on a passing run still mirrors the pass"
        "$bad"$'\n'"$ok_no_url"$'\n'"$own|0|0|an absent details_url on a passing run still mirrors the pass"
        "$ok"$'\n'"$action_required"$'\n'"$own|0|1|a newest action_required verdict fails"
        "$ok"$'\n'"$stale"$'\n'"$own|0|1|a newest stale verdict fails"
        "$own|0|1|only this run's own check run → nothing to mirror, fail closed"
        "|1|1|gh api failure → fail closed"
    )

    local row fixture ghrc expected desc rc stub violations=0 i=0
    for row in "${cases[@]}"; do
        IFS='|' read -r -d '' fixture ghrc expected desc <<<"$row" || true
        desc="${desc%$'\n'}"
        i=$((i + 1))
        stub="$TEST_TEMP_DIR/gh-stub-$i"
        write_gh_stub "$stub" "$fixture" "$ghrc"
        rc=$(run_pr_tier_mirror "$script" "$stub")
        if [ "$rc" != "$expected" ]; then
            /usr/bin/echo "  row ${i}: expected exit ${expected}, got ${rc} — ${desc}"
            violations=$((violations + 1))
        fi
        if [ ! -s "$stub/gh.calls" ]; then
            /usr/bin/echo "  row ${i}: gh was never called — the mirror path was not taken"
            violations=$((violations + 1))
        fi
    done

    # The query itself: without filter=all the API returns only the latest
    # run per name (which may be this run's own), and the wrong SHA or check
    # name mirrors an unrelated verdict. The stub ignores its arguments, so
    # pin them here — the EXACT argv of exactly one call, element by element,
    # not substrings of a flattened log (#1271). --paginate is pinned too:
    # without it a SHA with more than one page of PR Tier runs truncates
    # silently and the newest run may be missed.
    local calls expected_calls
    calls=$(/usr/bin/cat "$TEST_TEMP_DIR/gh-stub-1/gh.calls" 2>/dev/null) || calls=""
    expected_calls=$(/usr/bin/printf '%s\n' \
        api \
        --paginate \
        'repos/owner/repo/commits/deadbeef/check-runs?check_name=PR%20Tier&filter=all&per_page=100' \
        --jq \
        '.check_runs[]' \
        ---)
    if [ "$calls" != "$expected_calls" ]; then
        /usr/bin/echo "  gh argv differs from the pinned query:"
        /usr/bin/echo "    expected: $(/usr/bin/printf '%s' "$expected_calls" | /usr/bin/tr '\n' ' ')"
        /usr/bin/echo "    got:      $(/usr/bin/printf '%s' "${calls:-<no call>}" | /usr/bin/tr '\n' ' ')"
        violations=$((violations + 1))
    fi

    # Discriminating row: a `ci/full-build` add is a RELEVANT event and must
    # not mirror. With DETECT_RESULT=skipped it reaches the #909 gate and
    # fails — and gh is never called. (The mirror would have passed on $ok.)
    stub="$TEST_TEMP_DIR/gh-stub-relevant"
    write_gh_stub "$stub" "$ok" 0
    rc=$(run_pr_tier_mirror "$script" "$stub" "ci/full-build")
    if [ "$rc" != "1" ] || [ -e "$stub/gh.calls" ]; then
        /usr/bin/echo "  ci/full-build label: expected exit 1 with no gh call, got ${rc} (gh called: $([ -e "$stub/gh.calls" ] && echo yes || echo no))"
        violations=$((violations + 1))
    fi

    if [ "$violations" -eq 0 ]; then
        assert_true true "pr-tier mirrors the last verdict correctly across all $((${#cases[@]} + 1)) label states"
    else
        assert_true false "$violations pr-tier mirror case(s) wrong (see above)"
    fi
}

# The trigger/concurrency/gate shape the mirror depends on. Each is a
# separate silent failure: without `labeled` the label does nothing (#1099);
# without the detect-changes gate an unrelated label rebuilds the matrix;
# without a PR-scoped group a push + label add build twice; and if an
# irrelevant run could cancel, it would kill the real run it then mirrors.
test_pr_tier_label_trigger_shape() {
    require_yq || return 0
    local wf="$PR_TIER_WORKFLOW" out

    out=$(run_yq '(.on // .["on"]).pull_request.types | contains(["labeled"])' "$wf") || out="FAILED"
    assert_equals "true" "$out" "test-pr.yml triggers on pull_request 'labeled'"

    out=$(run_yq '.concurrency.group' "$wf") || out="FAILED"
    assert_equals 'test-pr-${{ github.event.pull_request.number }}' "$out" \
        "test-pr.yml concurrency group is PR-scoped"

    out=$(run_yq '.concurrency["cancel-in-progress"]' "$wf") || out="FAILED"
    assert_equals "\${{ github.event.action != 'labeled' || github.event.label.name == 'ci/full-build' }}" "$out" \
        "only relevant events cancel an in-progress run"

    out=$(run_yq '.jobs["detect-changes"].if' "$wf") || out="FAILED"
    assert_equals "github.event.action != 'labeled' || github.event.label.name == 'ci/full-build'" "$out" \
        "detect-changes skips irrelevant-label events"

    out=$(run_yq '.jobs["pr-tier"].if' "$wf") || out="FAILED"
    assert_equals "always()" "$out" "pr-tier still always reports (#904)"

    # The mirror's `gh api` call needs checks:read. Without it the call 403s,
    # the mirror fails closed, and EVERY irrelevant label add turns the PR red
    # — a loud failure, but one this pins before it ships (#1271).
    out=$(run_yq '.jobs["pr-tier"].permissions.checks' "$wf") || out="FAILED"
    assert_equals "read" "$out" "pr-tier grants checks: read for the mirror query"
}

run_test test_pr_tier_verdict_matrix "pr-tier's verdict is correct across upstream states"
run_test test_pr_tier_mirror_verdict "pr-tier mirrors the last verdict on an irrelevant label (#1099)"
run_test test_pr_tier_label_trigger_shape "test-pr.yml label trigger, concurrency, and gates (#1099)"

generate_report
