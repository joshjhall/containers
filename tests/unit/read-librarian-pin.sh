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

# A Dockerfile whose last line is a pin with no trailing newline: `read`
# returns non-zero on that line, and a loop that drops it under-counts. A
# duplicate there would then pass as one pin.
test_unterminated_last_line_counted() {
    local df
    df=$(command printf 'ARG LIBRARIAN_REF=v0.18.0\nARG LIBRARIAN_REF=v0.19.0' | write_dockerfile)
    run_pin "$df"
    assert_rejected "unterminated duplicate pin"
    assert_contains "$ERR" "found 2" "an unterminated last pin is still counted"

    df=$(command printf 'FROM debian:13\nARG LIBRARIAN_REF=v0.18.0' | write_dockerfile)
    run_pin "$df"
    assert_equals "0" "$RC" "a lone unterminated pin is accepted"
    assert_equals "v0.18.0" "$OUT" "a lone unterminated pin is printed"
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
    local suffix df
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

# A pin Docker would honour but the single-key matcher cannot see must fail
# closed, or a second pin hides from the count (#1580).
test_multi_key_pin_rejected() {
    local df
    df=$(command printf 'FROM debian:13\nARG FOO=1 LIBRARIAN_REF=v0.19.0\n' | write_dockerfile)
    run_pin "$df"
    assert_rejected "lone multi-key pin"
    assert_contains "$ERR" "unsupported ARG form for LIBRARIAN_REF" "multi-key pin names the form rule"
    assert_contains "$ERR" "at line 2" "multi-key error names the line"

    df=$(command printf 'ARG LIBRARIAN_REF=v0.18.0\narg FOO=1 LIBRARIAN_REF=v0.19.0\n' | write_dockerfile)
    run_pin "$df"
    assert_rejected "multi-key duplicate pin"
    assert_contains "$ERR" "unsupported ARG form for LIBRARIAN_REF" "multi-key duplicate is not silently skipped"

    # Pin as the FIRST key: must hit the form rule, not merely the shape check.
    df=$(command printf 'FROM debian:13\nARG LIBRARIAN_REF=v0.19.0 FOO=1\n' | write_dockerfile)
    run_pin "$df"
    assert_rejected "multi-key pin, pin first"
    assert_contains "$ERR" "unsupported ARG form for LIBRARIAN_REF in $df at line 2" "pin-first multi-key hits the form rule"
}

# `# escape=`` makes backtick the continuation character, so a continued pin
# would slip past the backslash join. Any non-default escape is rejected.
test_escape_directive_rejected() {
    local df
    df=$(command printf '# escape=`\nFROM debian:13\nARG LIBRARIAN_REF=v0.18.0\nARG FOO=1 `\n    LIBRARIAN_REF=v0.19.0\n' | write_dockerfile)
    run_pin "$df"
    assert_rejected "backtick escape directive"
    assert_contains "$ERR" "unsupported '# escape=' parser directive in $df at line 1" "escape directive is named"

    # The default escape, and an escape-looking comment AFTER the directive
    # block (no longer a directive), are both fine.
    df=$(command printf '# syntax=docker/dockerfile:1\n# escape=\\\nFROM debian:13\n# escape=`\nARG LIBRARIAN_REF=v0.18.0\n' | write_dockerfile)
    run_pin "$df"
    assert_equals "0" "$RC" "default escape + late comment are accepted"
    assert_equals "v0.18.0" "$OUT" "pin printed under the default escape"
}

test_continued_pin_rejected() {
    local df
    df=$(command printf 'FROM debian:13\nARG \\\n    LIBRARIAN_REF=v0.19.0\n' | write_dockerfile)
    run_pin "$df"
    assert_rejected "pin on a continuation line"
    assert_contains "$ERR" "unsupported ARG form for LIBRARIAN_REF in $df at line 2" "continued pin names its instruction's line"

    df=$(command printf 'ARG LIBRARIAN_REF=v0.18.0 \\\n    FOO=1\n' | write_dockerfile)
    run_pin "$df"
    assert_rejected "pin with a continued tail"
    assert_contains "$ERR" "unsupported ARG form for LIBRARIAN_REF" "continued single-key pin is rejected"

    # Docker skips comment and blank lines inside a continuation.
    df=$(command printf 'ARG LIBRARIAN_REF=v0.18.0\nARG FOO=1 \\\n# note\n\n    LIBRARIAN_REF=v0.19.0\n' | write_dockerfile)
    run_pin "$df"
    assert_rejected "continued pin across comment + blank lines"
    assert_contains "$ERR" "at line 2" "continuation through a comment is still joined"
}

# The new rejection must not fire on LIBRARIAN_REF outside an ARG key: the
# repo Dockerfile's ENV block carries `LIBRARIAN_REF=${LIBRARIAN_REF} \`.
test_other_instruction_mention_ignored() {
    local df
    df=$(
        write_dockerfile <<'EOF'
ARG LIBRARIAN_REF=v0.18.0
ARG OTHER_LIBRARIAN_REF=x
ENV FOO=1 \
    LIBRARIAN_REF=${LIBRARIAN_REF} \
    BAR=2
RUN echo LIBRARIAN_REF=v9.9.9
EOF
    )
    run_pin "$df"
    assert_equals "0" "$RC" "non-ARG and non-key mentions are ignored"
    assert_equals "v0.18.0" "$OUT" "the single pin is printed"
    assert_equals "" "$ERR" "no error output"
}

# Count LIBRARIAN_REF mentions in a workflow file outside whole-line comments.
# Only lines whose first non-blank character is `#` are dropped: stripping a
# trailing ` #...` would also cut a `#` inside a quoted shell string and hide a
# read after it. ci.yml
# must have none: every read goes through bin/read-librarian-pin.sh, whose
# call line does not name the variable. Any inline read — sed, grep, awk, cut
# — has to name LIBRARIAN_REF, so this catches every spelling (#1580).
count_inline_pin_reads() {
    command grep -v '^[[:space:]]*#' "$1" | command grep -ci 'LIBRARIAN_REF' || true
}

# Both ci.yml steps must go through the script, and no inline read may creep
# back in (it would silently drop the count guard).
test_ci_steps_use_shared_script() {
    local calls inline
    calls=$(command grep -c 'ref=$(bin/read-librarian-pin.sh Dockerfile)' "$CI_WORKFLOW" || true)
    assert_equals "2" "$calls" "both Read librarian pin steps call bin/read-librarian-pin.sh"
    inline=$(count_inline_pin_reads "$CI_WORKFLOW")
    assert_equals "0" "$inline" "no inline read of LIBRARIAN_REF remains in ci.yml"
}

# The guard above must catch inline reads in any spelling, and must not count
# the explanatory comments ci.yml carries.
test_inline_read_guard_discriminates() {
    local yml n step
    yml="$TEST_TEMP_DIR/ci.yml"
    for step in \
        "ref=\$(command sed -nE 's/^ARG LIBRARIAN_REF=//p' Dockerfile)" \
        "ref=\$(command grep -oP 'LIBRARIAN_REF=\\K.*' Dockerfile)" \
        "ref=\$(command awk -F= '/^arg librarian_ref=/ {print \$2}' Dockerfile)" \
        "ref=\$(command grep LIBRARIAN_REF Dockerfile | command cut -d= -f2)" \
        "x=\"a #b\"; ref=\$(command grep LIBRARIAN_REF Dockerfile)" \
        "echo hi # LIBRARIAN_REF trailing note"; do
        command printf '      - run: |\n          %s\n' "$step" >"$yml"
        n=$(count_inline_pin_reads "$yml")
        assert_equals "1" "$n" "inline read counted: $step"
    done
    command printf '      # read from `ARG LIBRARIAN_REF`\n  # LIBRARIAN_REF again\n      - run: echo hi\n      env:\n        REQUIRE_LIBRARIAN_PARITY: 1\n' >"$yml"
    n=$(count_inline_pin_reads "$yml")
    assert_equals "0" "$n" "whole-line comments and REQUIRE_LIBRARIAN_PARITY are not counted"
}

run_test test_single_valid_line_prints_ref "single valid ARG line prints the ref"
run_test test_quoted_value_accepted "quoted ARG value is accepted and unquoted"
run_test test_two_distinct_lines_rejected "two distinct ARG lines are rejected (#1555)"
run_test test_two_identical_lines_rejected "two identical ARG lines are rejected (#1555)"
run_test test_valid_plus_invalid_line_rejected "valid + invalid ARG lines are rejected (#1555)"
run_test test_indented_or_lowercase_duplicate_rejected "indented / lowercase duplicate ARG lines are rejected"
run_test test_bare_redeclaration_allowed "bare ARG re-declaration is not a second pin"
run_test test_unterminated_last_line_counted "a pin on an unterminated last line is counted"
run_test test_bare_only_rejected "bare-only ARG re-declaration is rejected as zero pins"
run_test test_zero_lines_rejected "missing ARG line is rejected"
run_test test_non_tag_value_rejected "non-vX.Y.Z values are rejected"
run_test test_default_dockerfile_argument "no argument defaults to ./Dockerfile"
run_test test_trailing_junk_rejected "CRLF / trailing whitespace after the tag is rejected"
run_test test_missing_file_rejected "unreadable Dockerfile is rejected"
run_test test_repo_dockerfile_passes "repo Dockerfile carries exactly one valid pin"
run_test test_multi_key_pin_rejected "multi-key ARG pin is rejected, not skipped (#1580)"
run_test test_escape_directive_rejected "non-default # escape= directive is rejected (#1580)"
run_test test_continued_pin_rejected "backslash-continued ARG pin is rejected (#1580)"
run_test test_other_instruction_mention_ignored "LIBRARIAN_REF outside an ARG key is not a pin"
run_test test_ci_steps_use_shared_script "ci.yml pin steps share bin/read-librarian-pin.sh"
run_test test_inline_read_guard_discriminates "ci.yml inline-read guard catches any spelling (#1580)"

generate_report
