#!/usr/bin/env bash
# Unit tests for .conform.yaml scopes policy.
#
# Background (issue #409): `scopes: []` silently rejected every scoped
# commit, including the `chore(release):` format documented in
# docs/development/releasing.md. The fix curated a list from real git
# history.
#
# Conform compiles each scopes entry as a Go regex (see
# https://github.com/siderolabs/conform/blob/main/internal/policy/commit/check_conventional_commit.go
# — `regexp.MustCompile(scope)` + `re.MatchString(ccScope)`), and the
# match is unanchored. A bare `op` entry would silently allow
# `feat(operation):`. Every entry must therefore be anchored `^name$`.

set -euo pipefail

# Source test framework
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite ".conform.yaml scopes policy"

CONFORM="$PROJECT_ROOT/.conform.yaml"

# Required for these tests; bail with a clear message rather than
# producing confusing failures if absent.
if ! command -v yq >/dev/null 2>&1; then
    echo "SKIP: yq not available — install yq to run conform-scopes tests"
    generate_report
    exit 0
fi

# Minimum acceptance threshold for historical-coverage test (per issue #409
# acceptance criteria: ">95% of last 100 scoped commits would pass").
HISTORICAL_COVERAGE_MIN=95
HISTORICAL_COMMIT_WINDOW=300

# Run `yq eval <expr>` on $CONFORM, capturing stdout, stderr, and the exit
# code separately (#1100). A `yq ... | grep -q` pipeline discards yq's
# status and stderr, so a one-off CI failure could not be told apart from
# a genuinely missing scope. stderr is kept out of stdout so a yq warning
# can never be matched as a scope entry.
#
# Sets YQ_OUT, YQ_ERR and YQ_SETUP_FAILED; returns yq's exit code, or 1
# with YQ_SETUP_FAILED=1 if the scratch file couldn't be created (yq never
# ran). The flag is out-of-band so no yq exit code can be mistaken for a
# setup failure. Callers invoke this as `run_yq ... || rc=$?`, which
# disables errexit inside it, so a failed mktemp must be caught explicitly
# or it would surface as a yq failure.
run_yq() {
    local expr="$1" errfile rc=0
    YQ_OUT="" YQ_ERR="" YQ_SETUP_FAILED=0
    if ! errfile=$(command mktemp "${TMPDIR:-/tmp}/conform-scopes-yq.XXXXXX" 2>/dev/null) ||
        [ ! -f "$errfile" ]; then
        YQ_SETUP_FAILED=1
        YQ_ERR="mktemp failed under ${TMPDIR:-/tmp}"
        return 1
    fi
    YQ_OUT=$(yq eval "$expr" "$CONFORM" 2>"$errfile") || rc=$?
    YQ_ERR=$(<"$errfile")
    command rm -f "$errfile"
    return "$rc"
}

# Diagnostic for a non-zero run_yq: exit code, stderr, and what stdout held.
yq_failure_msg() {
    local rc="$1" lines=0
    if [ "${YQ_SETUP_FAILED:-0}" -eq 1 ]; then
        echo "run_yq setup failed before yq ran (rc=$rc): ${YQ_ERR:-<empty>}"
        return 0
    fi
    [ -n "$YQ_OUT" ] && lines=$(command wc -l <<<"$YQ_OUT")
    echo "yq failed (rc=$rc) reading $CONFORM — stderr: ${YQ_ERR:-<empty>}; stdout ($lines lines): ${YQ_OUT:-<empty>}"
}

SCOPES_EXPR='.policies[0].spec.conventional.scopes[]'

test_yaml_parseable() {
    if yq eval '.' "$CONFORM" >/dev/null 2>&1; then
        assert_true true ".conform.yaml parses as valid YAML"
    else
        assert_true false ".conform.yaml failed to parse with yq"
    fi
}

test_scopes_non_empty() {
    local count rc=0
    run_yq '.policies[0].spec.conventional.scopes | length' || rc=$?
    if [ "$rc" -ne 0 ]; then
        assert_true false "$(yq_failure_msg "$rc")"
        return 0
    fi
    count="$YQ_OUT"
    if ! [[ "$count" =~ ^[0-9]+$ ]]; then
        assert_true false "scopes length is not a number: '$count'"
    elif [ "$count" -gt 0 ]; then
        assert_true true "scopes list is non-empty (count=$count)"
    else
        assert_true false "scopes list is empty — regression of #409 (the original bug rejected every scoped commit)"
    fi
}

test_release_scope_present() {
    # `chore(release): ...` is what bin/release.sh emits and what
    # docs/development/releasing.md tells contributors to use. If this
    # check fails, releases break.
    local rc=0 lines=0 tail_lines
    run_yq "$SCOPES_EXPR" || rc=$?
    if [ "$rc" -ne 0 ]; then
        assert_true false "$(yq_failure_msg "$rc")"
    elif command grep -qE '^\^?release\$?$' <<<"$YQ_OUT"; then
        assert_true true "release scope present (regression guard for #409)"
    else
        # Line count + tail tell a truncated read apart from a removed scope.
        [ -n "$YQ_OUT" ] && lines=$(command wc -l <<<"$YQ_OUT")
        tail_lines=$(command tail -n 3 <<<"$YQ_OUT" | command tr '\n' ' ')
        assert_true false "release scope missing — chore(release): commits will fail the commit-msg hook (yq rc=0, read $lines lines, last: ${tail_lines:-<empty>}; stderr: ${YQ_ERR:-<empty>})"
    fi
}

test_scopes_are_anchored() {
    # Conform uses unanchored regex matching. Every entry must start with
    # `^` and end with `$`, otherwise short scopes leak (e.g. `op` would
    # match `feat(operation):`).
    local unanchored rc=0
    run_yq "$SCOPES_EXPR" || rc=$?
    if [ "$rc" -ne 0 ]; then
        assert_true false "$(yq_failure_msg "$rc")"
        return 0
    fi
    if [ -z "$YQ_OUT" ]; then
        # An empty list has no unanchored entries; don't pass vacuously.
        assert_true false "yq returned no scope entries from $CONFORM (stderr: ${YQ_ERR:-<empty>})"
        return 0
    fi
    unanchored=$(command grep -vE '^\^[^$]+\$$' <<<"$YQ_OUT" || true)
    if [ -z "$unanchored" ]; then
        assert_true true "every scope entry is anchored ^...\$"
    else
        echo "  unanchored entries (would substring-match in conform):"
        echo "$unanchored" | command sed 's/^/    /'
        assert_true false "$(echo "$unanchored" | command wc -l) scope entr(y/ies) missing ^...\$ anchors"
    fi
}

test_historical_scopes_covered() {
    # Survey scopes used in recent commit history and confirm the policy
    # accepts them. Tolerance: HISTORICAL_COVERAGE_MIN percent (95% by
    # default, per the issue's acceptance criterion).
    local total=0
    local covered=0
    local missing=()
    local allowed_bare rc=0
    run_yq "$SCOPES_EXPR" || rc=$?
    if [ "$rc" -ne 0 ]; then
        assert_true false "$(yq_failure_msg "$rc")"
        return 0
    fi
    # Bare names (anchors stripped), computed once rather than per scope.
    allowed_bare=$(command sed 's/^\^//; s/\$$//' <<<"$YQ_OUT")

    # Skip gracefully on shallow clones (CI sometimes does --depth=1).
    if ! command -v git >/dev/null 2>&1; then
        echo "SKIP: git unavailable"
        return 0
    fi
    local commit_count
    commit_count=$(command git -C "$PROJECT_ROOT" log --oneline -"$HISTORICAL_COMMIT_WINDOW" 2>/dev/null | command wc -l)
    if [ "$commit_count" -lt 50 ]; then
        echo "SKIP: shallow git history ($commit_count commits) — coverage check needs ~$HISTORICAL_COMMIT_WINDOW"
        return 0
    fi

    local scope
    while IFS= read -r scope; do
        [ -z "$scope" ] && continue
        total=$((total + 1))
        # Scope must equal one of the bare allowlist names.
        if command grep -Fxq -- "$scope" <<<"$allowed_bare"; then
            covered=$((covered + 1))
        else
            missing+=("$scope")
        fi
    done < <(command git -C "$PROJECT_ROOT" log --pretty=format:'%s' -"$HISTORICAL_COMMIT_WINDOW" |
        command grep -oE '^[a-z]+\(([a-z0-9._-]+)\)' |
        command sed -E 's/^[a-z]+\(//; s/\)$//' |
        command sort -u)

    if [ "$total" -eq 0 ]; then
        echo "SKIP: no scoped commits found in last $HISTORICAL_COMMIT_WINDOW commits"
        return 0
    fi

    local percent=$((covered * 100 / total))
    if [ "$percent" -ge "$HISTORICAL_COVERAGE_MIN" ]; then
        assert_true true "historical scope coverage: $covered/$total = ${percent}% (>= ${HISTORICAL_COVERAGE_MIN}%)"
        if [ "${#missing[@]}" -gt 0 ]; then
            echo "  note: ${#missing[@]} historical scope(s) not in allowlist (under threshold, allowed):"
            command printf '    %s\n' "${missing[@]}"
        fi
    else
        echo "  missing scopes (used in history but not allowed):"
        command printf '    %s\n' "${missing[@]}"
        assert_true false "historical scope coverage ${percent}% < ${HISTORICAL_COVERAGE_MIN}% — add the missing scopes to .conform.yaml or raise the threshold deliberately"
    fi
}

test_run_yq_reports_failure() {
    # Drive the diagnostic path the checks above rely on (#1100): a yq
    # failure must surface a non-zero rc AND yq's stderr in the message,
    # not just an exit code. CONFORM is shadowed locally (dynamic scope)
    # so the fixture can't leak into the other tests.
    # run_test disables errexit here, so check the fixture explicitly: an
    # empty $scratch would point yq at /bad.yaml and pass on "no such file".
    local scratch rc=0 msg
    if ! scratch=$(command mktemp -d "${TMPDIR:-/tmp}/conform-scopes-test.XXXXXX") ||
        [ ! -d "$scratch" ] ||
        ! command printf 'policies: [\n  - {broken\n' >"$scratch/bad.yaml"; then
        assert_true false "fixture setup failed under ${TMPDIR:-/tmp}"
        return 0
    fi
    local CONFORM="$scratch/bad.yaml"
    run_yq "$SCOPES_EXPR" || rc=$?
    msg=$(yq_failure_msg "$rc")
    command rm -rf "$scratch"

    if [ "$rc" -eq 0 ]; then
        assert_true false "run_yq returned 0 on malformed YAML"
    elif [ -z "$YQ_ERR" ]; then
        assert_true false "run_yq captured no stderr for a yq failure (rc=$rc)"
    elif [[ "$YQ_OUT" == *"$YQ_ERR"* ]]; then
        assert_true false "yq stderr leaked into captured stdout: $YQ_OUT"
    elif [[ "$msg" != *"yq failed (rc=$rc) reading $CONFORM"* ]] || [[ "$msg" != *"stderr: $YQ_ERR"* ]]; then
        assert_true false "yq_failure_msg lacks rc, path, or stderr: $msg"
    else
        assert_true true "yq failure reported with rc=$rc and stderr"
    fi
    YQ_OUT="" YQ_ERR="" YQ_SETUP_FAILED=0
}

test_run_yq_reports_setup_failure() {
    # A scratch-file failure must be labeled as setup, never blamed on yq.
    # TMPDIR is shadowed with a regular file so mktemp fails
    # deterministically; run_yq expands it itself, so `local` suffices.
    local blocker rc=0 msg
    if ! blocker=$(command mktemp "${TMPDIR:-/tmp}/conform-scopes-blocker.XXXXXX") ||
        [ ! -f "$blocker" ]; then
        assert_true false "fixture setup failed under ${TMPDIR:-/tmp}"
        return 0
    fi
    local TMPDIR="$blocker"
    run_yq "$SCOPES_EXPR" || rc=$?
    msg=$(yq_failure_msg "$rc")
    command rm -f "$blocker"

    if [ "$rc" -eq 0 ] || [ "$YQ_SETUP_FAILED" -ne 1 ]; then
        assert_true false "run_yq didn't flag mktemp failure (rc=$rc, YQ_SETUP_FAILED=$YQ_SETUP_FAILED)"
    elif [[ "$msg" != *"setup failed before yq ran"* ]] || [[ "$msg" == *"yq failed"* ]]; then
        assert_true false "setup failure not labeled distinctly: $msg"
    else
        assert_true true "mktemp failure reported as setup, not yq"
    fi
    YQ_OUT="" YQ_ERR="" YQ_SETUP_FAILED=0
}

# Run one check against a fixture and print what it reported, followed by a
# `__status=<TEST_STATUS>` trailer (#1279). The subshell keeps the check's
# verdict off the framework's global counters, so a deliberately failing
# check can't fail this suite. CONFORM is the fixture path inside it only.
drive_check() {
    local fixture="$1" check="$2"
    (
        CONFORM="$fixture"
        TEST_STATUS=""
        "$check"
        echo "__status=${TEST_STATUS:-<none>}"
    ) 2>&1 | command sed 's/\x1b\[[0-9;]*m//g'
}

# Writes the malformed and empty-scopes fixtures into a new scratch dir and
# prints its path; returns 1, removing any partial dir, if a step fails.
make_check_fixtures() {
    local scratch
    if ! scratch=$(command mktemp -d "${TMPDIR:-/tmp}/conform-scopes-checks.XXXXXX") ||
        [ ! -d "$scratch" ]; then
        return 1
    fi
    if ! command printf 'policies: [\n  - {broken\n' >"$scratch/bad.yaml" ||
        ! command printf 'policies:\n  - type: commit\n    spec:\n      conventional:\n        scopes: []\n' >"$scratch/empty.yaml"; then
        command rm -rf "$scratch"
        return 1
    fi
    echo "$scratch"
}

test_checks_report_yq_failure() {
    # Each yq-reading check must turn a yq failure into exactly one failed
    # assertion naming the yq rc (#1279). One FAIL, not just a failed
    # status: a dropped `return 0` falls through to a second assertion,
    # which TEST_STATUS alone can't show.
    local scratch out check fails problems=()
    if ! scratch=$(make_check_fixtures); then
        assert_true false "fixture setup failed under ${TMPDIR:-/tmp}"
        return 0
    fi
    for check in test_scopes_non_empty test_release_scope_present \
        test_scopes_are_anchored test_historical_scopes_covered; do
        out=$(drive_check "$scratch/bad.yaml" "$check")
        fails=$(command grep -cx 'FAIL' <<<"$out" || true)
        if ! command grep -qx '__status=failed' <<<"$out"; then
            problems+=("$check didn't fail")
        elif [[ "$out" != *"yq failed (rc="* ]]; then
            problems+=("$check failure doesn't name the yq rc")
        elif [ "$fails" -ne 1 ]; then
            problems+=("$check recorded $fails failed assertions, expected 1")
        fi
    done
    command rm -rf "$scratch"

    if [ "${#problems[@]}" -eq 0 ]; then
        assert_true true "every yq-reading check reports a yq failure once"
    else
        assert_true false "$(command printf '%s; ' "${problems[@]}")"
    fi
}

test_empty_scopes_fail_closed() {
    # `scopes: []` parses cleanly, so only the per-check guards stand between
    # it and a vacuous pass (#1279).
    local scratch out problems=()
    if ! scratch=$(make_check_fixtures); then
        assert_true false "fixture setup failed under ${TMPDIR:-/tmp}"
        return 0
    fi
    out=$(drive_check "$scratch/empty.yaml" test_scopes_are_anchored)
    if ! command grep -qx '__status=failed' <<<"$out" || [[ "$out" != *"no scope entries"* ]]; then
        problems+=("test_scopes_are_anchored didn't fail on no scope entries")
    fi
    out=$(drive_check "$scratch/empty.yaml" test_scopes_non_empty)
    if ! command grep -qx '__status=failed' <<<"$out" || [[ "$out" != *"scopes list is empty"* ]]; then
        problems+=("test_scopes_non_empty didn't fail on an empty list")
    fi
    command rm -rf "$scratch"

    if [ "${#problems[@]}" -eq 0 ]; then
        assert_true true "empty scopes list fails the anchored and non-empty checks"
    else
        assert_true false "$(command printf '%s; ' "${problems[@]}")"
    fi
}

run_test test_yaml_parseable ".conform.yaml is valid YAML"
run_test test_scopes_non_empty "scopes list is non-empty"
run_test test_release_scope_present "release scope present (regression for #409)"
run_test test_scopes_are_anchored "every scope is anchored ^...\$"
run_test test_historical_scopes_covered ">=${HISTORICAL_COVERAGE_MIN}% of historical scopes are allowed"
run_test test_run_yq_reports_failure "yq failures report rc and stderr (#1100)"
run_test test_run_yq_reports_setup_failure "scratch-file failures are not blamed on yq (#1100)"
run_test test_checks_report_yq_failure "each check reports a yq failure exactly once (#1279)"
run_test test_empty_scopes_fail_closed "empty scopes list fails closed (#1279)"

generate_report
