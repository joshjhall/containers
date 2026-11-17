#!/usr/bin/env bash
# Unit tests for the path-filtered rust-test decision and its `Rust Tests`
# rollup in .github/workflows/ci.yml (#1593, #1653).
#
# `Rust Tests` is a required context (tests/unit/required-checks.sh proves it
# always REPORTS). This suite proves:
#   - bin/rust-test-matrix.sh says run=false for a non-Rust PR, run=true with
#     the full ubuntu/macOS/Windows matrix for a Rust PR and every non-PR
#     event, and fails SAFE (run=true, full matrix) when the diff cannot be
#     computed;
#   - the shipped Summarize block passes only when the detector succeeded AND
#     either every matrix leg succeeded or rust-test was skipped because the
#     detector said run=false — never on `cancelled`, nor on a skip the
#     detector did not ask for (#904);
#   - the job wiring (needs, if gates, always(), fromJSON matrix) behind both.
#
# The rollup is extracted from the workflow and EXECUTED, not re-described.
#
# Run via: ./tests/run_unit_tests.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/framework.sh
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "Rust Tests matrix + rollup"

# shellcheck source=tests/framework/helpers/required-checks.sh
source "$SCRIPT_DIR/../framework/helpers/required-checks.sh"

# Overridable so a mutation check can point the suite at scratch copies; never
# mutate the tracked files to prove a row bites.
CI_WORKFLOW="${CI_WORKFLOW:-$PROJECT_ROOT/.github/workflows/ci.yml}"
MATRIX_SCRIPT="${MATRIX_SCRIPT:-$PROJECT_ROOT/bin/rust-test-matrix.sh}"

readonly FULL='["ubuntu-26.04","macos-26","windows-2025"]'
readonly SKIP_MATRIX='["ubuntu-26.04"]'
# The detector's whole answer, as the two lines it appends to $GITHUB_OUTPUT.
readonly RUN_FULL="run=true matrix=$FULL"
readonly SKIP="run=false matrix=$SKIP_MATRIX"

# Build a throwaway repo whose `origin/main` is the base commit (README.md +
# a Dockerfile pinning LIBRARIAN_REF), then put one commit touching $1 on top
# as HEAD. Prints the repo path. Several paths may be given as one
# comma-separated argument; "path:line" appends that line instead of "x",
# and "path:=text" REPLACES the file with text (printf %b, so \n splits
# lines) — the only way to express an in-place edit or a deleted line.
_pr_repo() {
    local changed="$1" repo
    repo="$(/usr/bin/mktemp -d "$TEST_TEMP_DIR/repo.XXXXXX")"
    (
        # A leaked GIT_DIR would point every command at the outer repo.
        unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
        cd "$repo"
        git init -q -b main .
        git config user.email t@example.com
        git config user.name t
        /usr/bin/printf 'base\n' >README.md
        # A base Dockerfile carrying the pin, so a PR can edit around it or move it.
        /usr/bin/printf 'FROM scratch\nARG LIBRARIAN_REF=v0.0.1\n' >Dockerfile
        git add README.md Dockerfile
        git commit -qm base
        git update-ref refs/remotes/origin/main HEAD
        local f content
        IFS=',' read -ra files <<<"$changed"
        for f in "${files[@]}"; do
            content='x'
            case "$f" in *:*)
                content="${f#*:}"
                f="${f%%:*}"
                ;;
            esac
            /usr/bin/mkdir -p "$(/usr/bin/dirname "$f")"
            case "$content" in
                =*) /usr/bin/printf '%b\n' "${content#=}" >"$f" ;;
                *) /usr/bin/printf '%s\n' "$content" >>"$f" ;;
            esac
            git add "$f"
        done
        git commit -qm change
    ) >/dev/null 2>&1 || return 1
    /usr/bin/printf '%s\n' "$repo"
}

# Run the detector in $1 and print its output joined onto one line
# ("run=… matrix=…") so a whole answer compares in one string.
_matrix_in() {
    local repo="$1" out
    shift
    out="$(
        unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
        cd "$repo" && bash "$MATRIX_SCRIPT" "$@" 2>/dev/null
    )" || return $?
    /usr/bin/printf '%s\n' "$out" | /usr/bin/paste -sd' ' -
}

test_matrix_by_changed_path() {
    # changed path | expected matrix | why
    local -a cases=(
        "bin/check-versions.sh|$SKIP|a bin/-only PR skips rust-test"
        "tests/unit/foo.sh|$SKIP|a tests/-only PR skips rust-test"
        "docs/operations/ci-tiers.md|$SKIP|a docs-only PR skips rust-test"
        ".claude/memory/x.md|$SKIP|a memory-only PR (#1652) skips rust-test"
        "crates/stibbons/src/lib.rs|$RUN_FULL|a crates/ PR runs all three OSes"
        "Cargo.toml|$RUN_FULL|a Cargo.toml PR runs all three OSes"
        "Cargo.lock|$RUN_FULL|a Cargo.lock PR runs all three OSes"
        "rust-toolchain.toml|$RUN_FULL|a rust-toolchain PR runs all three OSes"
        "docs/a.md,bin/b.sh,crates/stibbons/src/lib.rs|$RUN_FULL|a Rust path is not masked by other changed files"
        ".cargo/config.toml|$RUN_FULL|cargo config changes build behaviour"
        "clippy.toml|$RUN_FULL|clippy config changes the lint gate"
        ".rustfmt.toml|$RUN_FULL|rustfmt config changes the fmt gate"
        "VERSION|$RUN_FULL|VERSION is stamped into stibbons by build.rs"
        ".github/workflows/ci.yml|$RUN_FULL|a PR editing the rust-test job must run it"
        "bin/read-librarian-pin.sh|$RUN_FULL|the parity test's pin reader feeds rust-test"
        "Dockerfile|$SKIP|a Dockerfile edit that leaves LIBRARIAN_REF alone skips"
        "Dockerfile:ARG LIBRARIAN_REF=v9.9.9|$RUN_FULL|adding a librarian pin line re-runs the parity test"
        "Dockerfile:=FROM scratch\\nARG LIBRARIAN_REF=v0.0.2|$RUN_FULL|bumping the pin in place re-runs the parity test"
        "Dockerfile:=FROM scratch|$RUN_FULL|deleting the pin line re-runs the parity test"
        "Dockerfile:=FROM debian\\nARG LIBRARIAN_REF=v0.0.1|$SKIP|rewriting another line beside an unchanged pin skips"
    )
    local row path want why repo got violations=0
    for row in "${cases[@]}"; do
        IFS='|' read -r path want why <<<"$row"
        if ! repo="$(_pr_repo "$path")"; then
            assert_true false "could not build a scratch repo for $path"
            return 0
        fi
        got="$(_matrix_in "$repo" pull_request main)" || got="EXIT $?"
        if [ "$got" != "$want" ]; then
            /usr/bin/echo "  $path: expected $want, got $got — $why"
            violations=$((violations + 1))
        fi
    done
    assert_equals 0 "$violations" "PR decision is right for all ${#cases[@]} changed-path shapes"
}

test_matrix_full_for_non_pr_events() {
    local repo ev got violations=0
    repo="$(_pr_repo docs/x.md)" || {
        assert_true false "could not build a scratch repo"
        return 0
    }
    # A docs-only diff would skip on a PR: proves the event decides.
    for ev in push schedule workflow_dispatch; do
        got="$(_matrix_in "$repo" "$ev" main)"
        if [ "$got" != "$RUN_FULL" ]; then
            /usr/bin/echo "  $ev: expected $RUN_FULL, got $got"
            violations=$((violations + 1))
        fi
    done
    assert_equals 0 "$violations" "push, schedule and dispatch always run the full matrix"
}

test_matrix_fails_safe() {
    local repo got
    repo="$(_pr_repo docs/x.md)" || {
        assert_true false "could not build a scratch repo"
        return 0
    }
    got="$(_matrix_in "$repo" pull_request no-such-base)"
    assert_equals "$RUN_FULL" "$got" "an unresolvable base ref runs the full matrix, never the skip"
    got="$(_matrix_in "$repo" pull_request "")"
    assert_equals "$RUN_FULL" "$got" "a PR with no base ref runs the full matrix, never the skip"
}

# --- rollup verdict ----------------------------------------------------------

extract_rollup_script() {
    local dest="$1"
    yq -r '.jobs["rust-test-result"].steps[] | select(.name == "Summarize") | .run' \
        "$CI_WORKFLOW" 2>/dev/null >"$dest" || return 1
    [ -s "$dest" ] || return 1
    ! /usr/bin/grep -qx 'null' "$dest" || return 1
}

test_rollup_verdict_matrix() {
    require_yq || return 0
    local script="$TEST_TEMP_DIR/rust-tests.sh"
    if ! extract_rollup_script "$script"; then
        assert_true false "could not extract rust-test-result's 'Summarize' step from ci.yml"
        return 0
    fi
    # detect result | rust-test result | detector run output | expected exit | why
    # The passing rows matter as much as the failing ones: a rollup that failed
    # everything would satisfy every other row while blocking every PR.
    local -a cases=(
        "success|success|true|0|detector and every leg passed"
        "success|skipped|false|0|a no-Rust PR's skip, asked for by the detector, passes (#1653)"
        "success|failure|true|1|a failing leg fails the rollup"
        "success|cancelled|true|1|a cancelled rust-test fails the rollup"
        "success|cancelled|false|1|a cancelled rust-test fails even when the detector said skip"
        "success|failure|false|1|a failing rust-test fails even when the detector said skip"
        "success|skipped|true|1|a skip the detector did not ask for is never a pass"
        "success|skipped||1|a skip with no run output is never a pass"
        "success|skipped|False|1|only the exact string 'false' admits a skip"
        "failure|skipped|false|1|a failed detector fails the rollup, whatever it printed"
        "cancelled|skipped|false|1|a cancelled detector fails the rollup"
        "skipped|skipped||1|a skipped detector fails the rollup"
    )
    local row detect test run want why rc violations=0
    for row in "${cases[@]}"; do
        IFS='|' read -r detect test run want why <<<"$row"
        rc=0
        DETECT_RESULT="$detect" TEST_RESULT="$test" RUN="$run" MATRIX="$SKIP_MATRIX" \
            bash "$script" >/dev/null 2>&1 || rc=$?
        if [ "$rc" != "$want" ]; then
            /usr/bin/echo "  detect=$detect rust-test=$test run=${run:-<empty>}: expected exit $want, got $rc — $why"
            violations=$((violations + 1))
        fi
    done
    assert_equals 0 "$violations" "Rust Tests verdict is right across all ${#cases[@]} upstream states"
}

test_rollup_job_shape() {
    require_yq || return 0
    local out
    out=$(run_yq '.jobs["rust-test-result"].name' "$CI_WORKFLOW") || out="FAILED"
    assert_equals "Rust Tests" "$out" "the rollup's context name is the literal manifest entry"
    out=$(run_yq '.jobs["rust-test-result"].if' "$CI_WORKFLOW") || out="FAILED"
    assert_equals "always()" "$out" "the rollup always reports (#904)"
    out=$(run_yq '.jobs["rust-test-result"].needs | join(",")' "$CI_WORKFLOW") || out="FAILED"
    assert_equals "rust-changes,rust-test" "$out" "the rollup reads both the detector and the matrix"
    out=$(run_yq '.jobs["rust-test"].strategy.matrix.os' "$CI_WORKFLOW") || out="FAILED"
    assert_equals '${{ fromJSON(needs.rust-changes.outputs.matrix) }}' "$out" \
        "rust-test's OS list comes from the detector"
    local gate="needs.rust-changes.outputs.run == 'true'"
    out=$(run_yq '.jobs["rust-test"].if // "none"' "$CI_WORKFLOW") || out="FAILED"
    assert_equals "$gate" "$out" "rust-test runs only when the detector says run=true"
    out=$(run_yq '.jobs["rust-latest-stable"].if // "none"' "$CI_WORKFLOW") || out="FAILED"
    assert_equals "$gate" "$out" "rust-latest-stable follows rust-test's skip"
    out=$(run_yq '.jobs["rust-latest-stable"].needs' "$CI_WORKFLOW") || out="FAILED"
    assert_equals "rust-changes" "$out" "rust-latest-stable reads the detector"
    out=$(run_yq '.jobs["rust-changes"].outputs.run' "$CI_WORKFLOW") || out="FAILED"
    assert_equals '${{ steps.matrix.outputs.run }}' "$out" "the detector job exposes the run decision"
    out=$(run_yq '.jobs["rust-changes"].outputs.matrix' "$CI_WORKFLOW") || out="FAILED"
    assert_equals '${{ steps.matrix.outputs.matrix }}' "$out" "the detector job exposes the OS matrix"
    out=$(run_yq '.jobs["rust-test-result"].steps[] | select(.name == "Summarize") | .env.RUN' "$CI_WORKFLOW") || out="FAILED"
    assert_equals '${{ needs.rust-changes.outputs.run }}' "$out" \
        "the rollup reads the detector's run decision, not just its result"
    # build needs rust-test, and a skipped need skips build. run=false is
    # PR-only, so build must never run on a PR.
    out=$(run_yq '.jobs["build"].if' "$CI_WORKFLOW") || out="FAILED"
    assert_equals "github.event_name == 'push' || github.event_name == 'workflow_dispatch'" "$out" \
        "build runs only on push/dispatch, where rust-test is never skipped"
    out=$(run_yq '.jobs["rust-changes"].steps[] | select(.id == "matrix") | .run' "$CI_WORKFLOW") || out="FAILED"
    assert_contains "$out" 'bin/rust-test-matrix.sh "$EVENT_NAME" "$BASE_REF"' \
        "the detector job runs the tested script"
    assert_contains "$out" '>>"$GITHUB_OUTPUT"' "the detector's lines land in the step outputs"
    # Without full history origin/<base> is absent, the diff fails, and the
    # detector falls back to FULL on every PR — safe, but silently loses the
    # whole saving.
    out=$(run_yq '.jobs["rust-changes"].steps[] | select(.uses == "actions/checkout@v4") | .with["fetch-depth"]' "$CI_WORKFLOW") || out="FAILED"
    assert_equals "0" "$out" "the detector's checkout fetches full history so origin/<base> exists"
    out=$(run_yq '.on.schedule[0].cron' "$CI_WORKFLOW") || out="FAILED"
    assert_not_equals "null" "$out" "ci.yml has a nightly schedule for the full matrix"
}

run_test test_matrix_by_changed_path "rust-test decision follows the PR's changed paths"
run_test test_matrix_full_for_non_pr_events "non-PR events always run the full OS matrix"
run_test test_matrix_fails_safe "the detector fails safe to run=true and the full matrix"
run_test test_rollup_verdict_matrix "Rust Tests rollup verdict across upstream states"
run_test test_rollup_job_shape "Rust Tests rollup and matrix wiring in ci.yml"

generate_report
