#!/usr/bin/env bash
# Unit tests for bin/read-repo-baseline-pin.sh (#1754).
#
# The script prints the containers-db commit recorded in stibbons'
# assets/repo-baseline/SOURCE only when SOURCE is exactly one line of the form
# `containers-db <40-hex sha>`. CI feeds that SHA to `git fetch` and a checkout
# `ref:`, so a branch, tag, short SHA or anything option-like must be refused.
#
# Each case writes its own SOURCE under $TEST_TEMP_DIR; no tracked file is
# ever modified.
#
# Run via: ./tests/unit/read-repo-baseline-pin.sh (or ./tests/run_unit_tests.sh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/framework.sh
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "read-repo-baseline-pin.sh"

# Overridable so a mutation check can point the suite at a scratch copy.
PIN_SCRIPT="${PIN_SCRIPT:-$PROJECT_ROOT/bin/read-repo-baseline-pin.sh}"
CI_WORKFLOW="${CI_WORKFLOW:-$PROJECT_ROOT/.github/workflows/ci.yml}"

SHA=f4a49d653d9df4b1284b55d4d8750a0e393fe6f7

# Write $TEST_TEMP_DIR/SOURCE from the printf-style args; echo its path.
write_source() {
    local path="$TEST_TEMP_DIR/SOURCE"
    # shellcheck disable=SC2059 # the format is the fixture
    command printf "$@" >"$path"
    command printf '%s\n' "$path"
}

# Run the script; sets RC, OUT (stdout) and ERR (stderr).
run_pin() {
    local errfile="$TEST_TEMP_DIR/stderr"
    RC=0
    OUT=$(bash "$PIN_SCRIPT" "$@" 2>"$errfile") || RC=$?
    ERR=$(command cat "$errfile")
}

# A rejection must exit 1 AND leave stdout empty: stdout is what CI hands to
# `git fetch` / $GITHUB_OUTPUT, so a SHA printed before a failing check leaks.
assert_rejected() {
    assert_equals "1" "$RC" "$1 exits 1"
    assert_equals "" "$OUT" "$1 prints nothing on stdout"
    assert_contains "$ERR" "::error::" "$1 reports a ::error:: line"
}

test_valid_source_prints_sha() {
    run_pin "$(write_source 'containers-db %s\n' "$SHA")"
    assert_equals "0" "$RC" "valid SOURCE exits 0"
    assert_equals "$SHA" "$OUT" "stdout is exactly the SHA"
    assert_equals "" "$ERR" "no error output on success"
}

test_unterminated_line_accepted() {
    run_pin "$(write_source 'containers-db %s' "$SHA")"
    assert_equals "0" "$RC" "SOURCE without a trailing newline exits 0"
    assert_equals "$SHA" "$OUT" "stdout is exactly the SHA"
}

test_moving_or_short_refs_rejected() {
    local ref
    for ref in main v1.2.3 "${SHA:0:12}" "${SHA}0" "$(command printf '%s' "$SHA" | command tr 'a-f' 'A-F')" "--upload-pack=x"; do
        run_pin "$(write_source 'containers-db %s\n' "$ref")"
        assert_rejected "ref '$ref'"
        assert_contains "$ERR" "full commit sha" "ref '$ref' names the expected shape"
    done
}

test_wrong_origin_rejected() {
    run_pin "$(write_source 'librarian %s\n' "$SHA")"
    assert_rejected "librarian origin"
    run_pin "$(write_source 'librarian 0.18.0 +pygments-pin\n')"
    assert_rejected "legacy librarian SOURCE"
}

test_extra_tokens_rejected() {
    run_pin "$(write_source 'containers-db %s +local-patch\n' "$SHA")"
    assert_rejected "trailing token"
    run_pin "$(write_source 'containers-db %s \n' "$SHA")"
    assert_rejected "trailing whitespace"
    run_pin "$(write_source 'containers-db %s\r\n' "$SHA")"
    assert_rejected "CRLF line ending"
    run_pin "$(write_source ' containers-db %s\n' "$SHA")"
    assert_rejected "leading whitespace"
}

test_line_count_enforced() {
    run_pin "$(write_source 'containers-db %s\ncontainers-db %s\n' "$SHA" "$SHA")"
    assert_rejected "two identical lines"
    assert_contains "$ERR" "exactly one line, found 2" "error names the line count"
    run_pin "$(write_source '')"
    assert_rejected "empty SOURCE"
    assert_contains "$ERR" "exactly one line, found 0" "empty file counted as zero lines"
}

test_missing_file_rejected() {
    run_pin "$TEST_TEMP_DIR/does-not-exist"
    assert_rejected "missing SOURCE"
    assert_contains "$ERR" "cannot read" "error names the unreadable file"
    run_pin "$TEST_TEMP_DIR"
    assert_rejected "directory as SOURCE"
}

# The live pin must satisfy the rule, or both CI gates go red. No argument
# also exercises the default path.
test_repo_source_passes() {
    run_pin
    assert_equals "0" "$RC" "tracked SOURCE carries a valid pin"
    if ! [[ "$OUT" =~ ^[0-9a-f]{40}$ ]]; then
        assert_equals "<40-hex sha>" "$OUT" "tracked pin is a full SHA"
    fi
}

# Both ci.yml consumers go through the script, and the parity job no longer
# depends on librarian.
test_ci_uses_shared_script() {
    local calls inline
    calls=$(command grep -c 'sha=$(bin/read-repo-baseline-pin.sh)' "$CI_WORKFLOW" || true)
    assert_equals "2" "$calls" "both repo-baseline pin reads call bin/read-repo-baseline-pin.sh"
    inline=$(command grep -v '^[[:space:]]*#' "$CI_WORKFLOW" | command grep -c 'repo-baseline/SOURCE' || true)
    assert_equals "0" "$inline" "no inline read of repo-baseline/SOURCE remains in ci.yml"
    inline=$(command grep -v '^[[:space:]]*#' "$CI_WORKFLOW" | command grep -cE 'LIBRARIAN_RENDER_SH|REQUIRE_LIBRARIAN_PARITY' || true)
    assert_equals "0" "$inline" "render.sh parity no longer reads librarian"
}

# Print one ci.yml step: from the `- name: <name>` line (exact match) up to,
# not including, the next `- name:` line. Prints nothing if absent, so every
# caller first asserts on a line only that step carries.
ci_step() {
    command awk -v want="- name: $1" '
        { line = $0; sub(/^[[:space:]]+/, "", line) }
        on && line ~ /^- name: / { exit }
        line == want { on = 1 }
        on
    ' "$CI_WORKFLOW"
}

# matches_baseline_render_sh skips without the pinned commit, and a skip
# renders as a pass (#768). The rust-test job must therefore check
# containers-db out at the pinned SHA, point the test at it, AND set
# REQUIRE_BASELINE_PARITY, or parity goes green unrun.
test_ci_requires_parity() {
    local step
    step=$(ci_step "Checkout containers-db at the pin (for render.sh parity)")
    assert_contains "$step" "repository: joshjhall/containers-db" "found the parity checkout step"
    assert_contains "$step" "ref: \${{ steps.baseline.outputs.sha }}" "parity checkout is at the pinned SHA"
    assert_contains "$step" "path: _containers-db" "parity checkout lands where Run tests looks"
    assert_contains "$step" "persist-credentials: false" "parity checkout keeps the token out"

    step=$(ci_step "Read repo-baseline pin (for render.sh parity)")
    assert_contains "$step" "id: baseline" "the pin step is the one the checkout reads"

    step=$(ci_step "Run tests")
    assert_contains "$step" "cargo test --workspace" "found the rust-test Run tests step"
    assert_contains "$step" "REQUIRE_BASELINE_PARITY: \${{ runner.os == 'Linux' && '1' || '' }}" \
        "Run tests requires parity on Linux"
    assert_contains "$step" "CONTAINERS_DB_REPO: \${{ github.workspace }}/_containers-db" \
        "Run tests points parity at the containers-db checkout"
}

run_test test_valid_source_prints_sha "valid SOURCE prints the SHA"
run_test test_unterminated_line_accepted "SOURCE without a trailing newline is accepted"
run_test test_moving_or_short_refs_rejected "branches, tags, short/long/uppercase SHAs and options are rejected"
run_test test_wrong_origin_rejected "a non-containers-db origin is rejected"
run_test test_extra_tokens_rejected "trailing tokens, whitespace and CRLF are rejected"
run_test test_line_count_enforced "SOURCE must be exactly one line"
run_test test_missing_file_rejected "missing or non-file SOURCE is rejected"
run_test test_repo_source_passes "tracked SOURCE carries a valid pin"
run_test test_ci_uses_shared_script "ci.yml reads the pin via the shared script (#1754)"
run_test test_ci_requires_parity "ci.yml rust-test requires render.sh parity at the pin (#1754)"

generate_report
