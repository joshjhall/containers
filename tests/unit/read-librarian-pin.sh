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

# A rejection must exit 1 AND leave stdout empty: stdout is what the CI step
# writes into $GITHUB_OUTPUT, so a ref printed before a failing check leaks.
assert_rejected() {
    assert_equals "1" "$RC" "$1 exits 1"
    assert_equals "" "$OUT" "$1 prints nothing on stdout"
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
    assert_rejected "two ARG lines"
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
    assert_rejected "two identical ARG lines"
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
    assert_rejected "valid + invalid ARG lines"
    assert_contains "$ERR" "found 2" "rejected on count, before the shape check"
}

# Docker honours indented and lowercase instructions, so these are second pins
# too; a column-0, uppercase-only match would count 1 and pass.
test_indented_or_lowercase_duplicate_rejected() {
    local second df
    for second in '    ARG LIBRARIAN_REF=v0.19.0' 'arg LIBRARIAN_REF=v0.19.0' $'\tArg  LIBRARIAN_REF=v0.19.0'; do
        df=$(command printf 'ARG LIBRARIAN_REF=v0.18.0\n%s\n' "$second" | write_dockerfile)
        run_pin "$df"
        assert_rejected "duplicate '$second'"
        assert_contains "$ERR" "found 2" "'$second' is counted as a second pin"
    done
}

# A bare re-declaration (`ARG LIBRARIAN_REF`, no `=`) in a later stage sets no
# value, so it is not a second pin.
test_bare_redeclaration_allowed() {
    local df
    df=$(command printf 'FROM debian:13 AS base\nARG LIBRARIAN_REF=v0.18.0\nFROM base\nARG LIBRARIAN_REF\n' | write_dockerfile)
    run_pin "$df"
    assert_equals "0" "$RC" "bare re-declaration does not count as a pin"
    assert_equals "v0.18.0" "$OUT" "the single valued pin is printed"
}

# ...and a bare re-declaration alone is zero pins, not one.
test_bare_only_rejected() {
    local df
    df=$(command printf 'FROM debian:13\nARG LIBRARIAN_REF\n' | write_dockerfile)
    run_pin "$df"
    assert_rejected "bare-only ARG"
    assert_contains "$ERR" "found 0" "a valueless ARG is not counted as a pin"
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
    assert_rejected "no ARG line"
    assert_contains "$ERR" "found 0" "error reports zero matches"
}

test_non_tag_value_rejected() {
    local value df
    for value in main v1.2 1.2.3 v1.2.3-rc1 ""; do
        df=$(command printf 'ARG LIBRARIAN_REF=%s\n' "$value" | write_dockerfile)
        run_pin "$df"
        assert_rejected "non-tag value '$value'"
        assert_contains "$ERR" "is not a vX.Y.Z tag: '$value'" "shape error quotes '$value'"
    done
}

# No argument: the script reads ./Dockerfile from its cwd.
test_default_dockerfile_argument() {
    command printf 'ARG LIBRARIAN_REF=v2.3.4\n' | write_dockerfile >/dev/null
    RC=0
    OUT=$(cd "$TEST_TEMP_DIR" && bash "$PIN_SCRIPT" 2>/dev/null) || RC=$?
    assert_equals "0" "$RC" "no-argument run exits 0"
    assert_equals "v2.3.4" "$OUT" "no-argument run reads ./Dockerfile"
}

# A CRLF checkout or trailing blank leaves junk after the tag; it must fail
# closed on the shape check rather than reach a checkout `ref:`.
test_trailing_junk_rejected() {
    local df
    for suffix in $'\r' ' '; do
        df=$(command printf 'ARG LIBRARIAN_REF=v1.2.3%s\n' "$suffix" | write_dockerfile)
        run_pin "$df"
        assert_rejected "trailing junk after the tag"
        assert_contains "$ERR" "is not a vX.Y.Z tag" "trailing junk hits the shape check"
    done
}

test_missing_file_rejected() {
    run_pin "$TEST_TEMP_DIR/does-not-exist"
    assert_rejected "unreadable Dockerfile"
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
run_test test_indented_or_lowercase_duplicate_rejected "indented / lowercase duplicate ARG lines are rejected"
run_test test_bare_redeclaration_allowed "bare ARG re-declaration is not a second pin"
run_test test_bare_only_rejected "bare-only ARG re-declaration is rejected as zero pins"
run_test test_zero_lines_rejected "missing ARG line is rejected"
run_test test_non_tag_value_rejected "non-vX.Y.Z values are rejected"
run_test test_default_dockerfile_argument "no argument defaults to ./Dockerfile"
run_test test_trailing_junk_rejected "CRLF / trailing whitespace after the tag is rejected"
run_test test_missing_file_rejected "unreadable Dockerfile is rejected"
run_test test_repo_dockerfile_passes "repo Dockerfile carries exactly one valid pin"
run_test test_ci_steps_use_shared_script "ci.yml pin steps share bin/read-librarian-pin.sh"

generate_report
