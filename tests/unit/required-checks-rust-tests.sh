#!/usr/bin/env bash
# Unit tests for the path-filtered rust-test OS matrix and its `Rust Tests`
# rollup in .github/workflows/ci.yml (#1593).
#
# `Rust Tests` is a required context (tests/unit/required-checks.sh proves it
# always REPORTS). This suite proves:
#   - bin/rust-test-matrix.sh picks ubuntu-only for a non-Rust PR, the full
#     ubuntu/macOS/Windows matrix for a Rust PR and every non-PR event, and
#     fails SAFE (full matrix) when the diff cannot be computed;
#   - the shipped Summarize block passes only when the detector AND every
#     matrix leg succeeded — never on `skipped` or `cancelled` (#904);
#   - the job wiring (needs, always(), fromJSON matrix) that makes both true.
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
readonly LINUX_ONLY='["ubuntu-26.04"]'

# Build a throwaway repo whose `origin/main` is the base commit, then put
# one commit adding $1 on top as HEAD. Prints the repo path.
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
        git add README.md
        git commit -qm base
        git update-ref refs/remotes/origin/main HEAD
        /usr/bin/mkdir -p "$(/usr/bin/dirname "$changed")"
        /usr/bin/printf 'x\n' >"$changed"
        git add "$changed"
        git commit -qm change
    ) >/dev/null 2>&1 || return 1
    /usr/bin/printf '%s\n' "$repo"
}

_matrix_in() {
    local repo="$1"
    shift
    (
        unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
        cd "$repo" && bash "$MATRIX_SCRIPT" "$@" 2>/dev/null
    )
}

test_matrix_by_changed_path() {
    # changed path | expected matrix | why
    local -a cases=(
        "bin/check-versions.sh|$LINUX_ONLY|a bin/-only PR runs ubuntu only"
        "tests/unit/foo.sh|$LINUX_ONLY|a tests/-only PR runs ubuntu only"
        "docs/operations/ci-tiers.md|$LINUX_ONLY|a docs-only PR runs ubuntu only"
        "crates/stibbons/src/lib.rs|$FULL|a crates/ PR runs all three OSes"
        "Cargo.toml|$FULL|a Cargo.toml PR runs all three OSes"
        "Cargo.lock|$FULL|a Cargo.lock PR runs all three OSes"
        "rust-toolchain.toml|$FULL|a rust-toolchain PR runs all three OSes"
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
    assert_equals 0 "$violations" "PR matrix is right for all ${#cases[@]} changed-path shapes"
}

test_matrix_full_for_non_pr_events() {
    local repo ev got violations=0
    repo="$(_pr_repo docs/x.md)" || {
        assert_true false "could not build a scratch repo"
        return 0
    }
    # A docs-only diff would be ubuntu-only on a PR: proves the event decides.
    for ev in push schedule workflow_dispatch; do
        got="$(_matrix_in "$repo" "$ev" main)"
        if [ "$got" != "$FULL" ]; then
            /usr/bin/echo "  $ev: expected $FULL, got $got"
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
    assert_equals "$FULL" "$got" "an unresolvable base ref yields the full matrix, not ubuntu-only"
    got="$(_matrix_in "$repo" pull_request "")"
    assert_equals "$FULL" "$got" "a PR with no base ref yields the full matrix"
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
    # detect result | rust-test result | expected exit | why
    # The passing row matters as much as the failing ones: a rollup that failed
    # everything would satisfy every other row while blocking every PR.
    local -a cases=(
        "success|success|0|detector and every leg passed"
        "success|failure|1|a failing leg fails the rollup"
        "success|cancelled|1|a cancelled rust-test fails the rollup"
        "success|skipped|1|a skipped rust-test is never a pass"
        "failure|skipped|1|a failed detector fails the rollup"
        "cancelled|skipped|1|a cancelled detector fails the rollup"
    )
    local row detect test want why rc violations=0
    for row in "${cases[@]}"; do
        IFS='|' read -r detect test want why <<<"$row"
        rc=0
        DETECT_RESULT="$detect" TEST_RESULT="$test" MATRIX="$LINUX_ONLY" \
            bash "$script" >/dev/null 2>&1 || rc=$?
        if [ "$rc" != "$want" ]; then
            /usr/bin/echo "  detect=$detect rust-test=$test: expected exit $want, got $rc — $why"
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
    out=$(run_yq '.jobs["rust-test"].if // "none"' "$CI_WORKFLOW") || out="FAILED"
    assert_equals "none" "$out" "rust-test is never skipped by a job-level if (build needs it)"
    out=$(run_yq '.jobs["rust-changes"].steps[] | select(.id == "matrix") | .run' "$CI_WORKFLOW") || out="FAILED"
    assert_contains "$out" 'bin/rust-test-matrix.sh "$EVENT_NAME" "$BASE_REF"' \
        "the detector job runs the tested script"
    out=$(run_yq '.on.schedule[0].cron' "$CI_WORKFLOW") || out="FAILED"
    assert_not_equals "null" "$out" "ci.yml has a nightly schedule for the full matrix"
}

run_test test_matrix_by_changed_path "rust-test OS matrix follows the PR's changed paths"
run_test test_matrix_full_for_non_pr_events "non-PR events always get the full OS matrix"
run_test test_matrix_fails_safe "the matrix detector fails safe to the full matrix"
run_test test_rollup_verdict_matrix "Rust Tests rollup verdict across upstream states"
run_test test_rollup_job_shape "Rust Tests rollup and matrix wiring in ci.yml"

generate_report
