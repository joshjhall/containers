#!/usr/bin/env bash
# Unit tests for bin/read-librarian-pin.sh (#1555).
#
# Both ci.yml "Read librarian pin" steps call this script. It must print the
# Dockerfile's LIBRARIAN_REF only when exactly ONE `ARG LIBRARIAN_REF=` line
# exists and its value is a vX.Y.Z tag. The old inline `sed | grep -q` passed
# on a Dockerfile with two such lines (grep -q matches any line), so the
# two-line rows below are the regression guard.
#
# Each case writes its own Dockerfile under $TEST_TEMP_DIR; no tracked file is
# ever modified.
#
# Run via: ./tests/unit/read-librarian-pin.sh (or ./tests/run_unit_tests.sh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/framework.sh
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "read-librarian-pin.sh"

# Overridable so a mutation check can point the suite at a scratch copy.
PIN_SCRIPT="${PIN_SCRIPT:-$PROJECT_ROOT/bin/read-librarian-pin.sh}"
CI_WORKFLOW="${CI_WORKFLOW:-$PROJECT_ROOT/.github/workflows/ci.yml}"

# Write $TEST_TEMP_DIR/Dockerfile from stdin; echo its path.
write_dockerfile() {
    local path="$TEST_TEMP_DIR/Dockerfile"
    command cat >"$path"
    command printf '%s\n' "$path"
}

# Run the script; sets RC, OUT (stdout) and ERR (stderr).
run_pin() {
    local errfile="$TEST_TEMP_DIR/stderr"
    RC=0
    OUT=$(bash "$PIN_SCRIPT" "$@" 2>"$errfile") || RC=$?
    ERR=$(command cat "$errfile")
}

test_single_valid_line_prints_ref() {
    local df
    df=$(
        write_dockerfile <<'EOF'
FROM debian:13
ARG LIBRARIAN_REF=v0.18.0
RUN true
EOF
    )
    run_pin "$df"
    assert_equals "0" "$RC" "one valid ARG line exits 0"
    assert_equals "v0.18.0" "$OUT" "stdout is exactly the ref"
    assert_equals "" "$ERR" "no error output on success"
}

test_quoted_value_accepted() {
    local df
    df=$(
        write_dockerfile <<'EOF'
ARG LIBRARIAN_REF="v1.2.3"
EOF
    )
    run_pin "$df"
    assert_equals "0" "$RC" "quoted ARG value exits 0"
    assert_equals "v1.2.3" "$OUT" "quotes are stripped from the ref"
}

# The #1555 regression: two lines, both well-formed. The old check passed.
test_two_distinct_lines_rejected() {
    local df
    df=$(
        write_dockerfile <<'EOF'
ARG LIBRARIAN_REF=v0.18.0
ARG LIBRARIAN_REF=v0.19.0
EOF
    )
    run_pin "$df"
    assert_equals "1" "$RC" "two ARG lines exit 1"
    assert_equals "" "$OUT" "nothing reaches stdout (GITHUB_OUTPUT) on failure"
    assert_contains "$ERR" "expected exactly one ARG LIBRARIAN_REF line" "error names the count rule"
    assert_contains "$ERR" "found 2" "error reports the match count"
}

# Identical duplicates would collapse under a `sort -u`-style dedup; they must
# still fail — the Dockerfile is ambiguous about which line is authoritative.
test_two_identical_lines_rejected() {
    local df
    df=$(
        write_dockerfile <<'EOF'
ARG LIBRARIAN_REF=v0.18.0
ARG LIBRARIAN_REF=v0.18.0
EOF
    )
    run_pin "$df"
    assert_equals "1" "$RC" "two identical ARG lines exit 1"
    assert_contains "$ERR" "found 2" "identical duplicates still count as 2"
}

# One valid + one malformed: the old `grep -q` passed on the valid line.
test_valid_plus_invalid_line_rejected() {
    local df
    df=$(
        write_dockerfile <<'EOF'
ARG LIBRARIAN_REF=main
ARG LIBRARIAN_REF=v0.18.0
EOF
    )
    run_pin "$df"
    assert_equals "1" "$RC" "valid + invalid ARG lines exit 1"
    assert_contains "$ERR" "found 2" "rejected on count, before the shape check"
}

test_zero_lines_rejected() {
    local df
    df=$(
        write_dockerfile <<'EOF'
FROM debian:13
# ARG LIBRARIAN_REF=v0.18.0  (commented out: not a match)
EOF
    )
    run_pin "$df"
    assert_equals "1" "$RC" "no ARG line exits 1"
    assert_contains "$ERR" "found 0" "error reports zero matches"
}

test_non_tag_value_rejected() {
    local value df
    for value in main v1.2 1.2.3 v1.2.3-rc1 ""; do
        df=$(command printf 'ARG LIBRARIAN_REF=%s\n' "$value" | write_dockerfile)
        run_pin "$df"
        assert_equals "1" "$RC" "non-tag value '$value' exits 1"
        assert_contains "$ERR" "is not a vX.Y.Z tag: '$value'" "shape error quotes '$value'"
        assert_equals "" "$OUT" "nothing on stdout for '$value'"
    done
}

test_missing_file_rejected() {
    run_pin "$TEST_TEMP_DIR/does-not-exist"
    assert_equals "1" "$RC" "unreadable Dockerfile exits 1"
    assert_contains "$ERR" "cannot read" "error names the unreadable file"
}

# The live pin must satisfy the rule, or both CI gates go red.
test_repo_dockerfile_passes() {
    run_pin "$PROJECT_ROOT/Dockerfile"
    assert_equals "0" "$RC" "repo Dockerfile has exactly one valid pin"
    if ! [[ "$OUT" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        assert_equals "vX.Y.Z" "$OUT" "repo pin is a vX.Y.Z tag"
    fi
}

# Both ci.yml steps must go through the script, and the old inline read must
# not creep back into either (it would silently drop the count guard).
test_ci_steps_use_shared_script() {
    local calls inline
    calls=$(command grep -c 'ref=$(bin/read-librarian-pin.sh Dockerfile)' "$CI_WORKFLOW" || true)
    assert_equals "2" "$calls" "both Read librarian pin steps call bin/read-librarian-pin.sh"
    inline=$(command grep -c "s/^ARG LIBRARIAN_REF=" "$CI_WORKFLOW" || true)
    assert_equals "0" "$inline" "no inline sed read of ARG LIBRARIAN_REF remains in ci.yml"
}

run_test test_single_valid_line_prints_ref "single valid ARG line prints the ref"
run_test test_quoted_value_accepted "quoted ARG value is accepted and unquoted"
run_test test_two_distinct_lines_rejected "two distinct ARG lines are rejected (#1555)"
run_test test_two_identical_lines_rejected "two identical ARG lines are rejected (#1555)"
run_test test_valid_plus_invalid_line_rejected "valid + invalid ARG lines are rejected (#1555)"
run_test test_zero_lines_rejected "missing ARG line is rejected"
run_test test_non_tag_value_rejected "non-vX.Y.Z values are rejected"
run_test test_missing_file_rejected "unreadable Dockerfile is rejected"
run_test test_repo_dockerfile_passes "repo Dockerfile carries exactly one valid pin"
run_test test_ci_steps_use_shared_script "ci.yml pin steps share bin/read-librarian-pin.sh"

generate_report
