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

test_yaml_parseable() {
    if yq eval '.' "$CONFORM" >/dev/null 2>&1; then
        assert_true true ".conform.yaml parses as valid YAML"
    else
        assert_true false ".conform.yaml failed to parse with yq"
    fi
}

test_scopes_non_empty() {
    local count
    count=$(yq eval '.policies[0].spec.conventional.scopes | length' "$CONFORM")
    if [ "$count" -gt 0 ]; then
        assert_true true "scopes list is non-empty (count=$count)"
    else
        assert_true false "scopes list is empty — regression of #409 (the original bug rejected every scoped commit)"
    fi
}

test_release_scope_present() {
    # `chore(release): ...` is what bin/release.sh emits and what
    # docs/development/releasing.md tells contributors to use. If this
    # check fails, releases break.
    if yq eval '.policies[0].spec.conventional.scopes[]' "$CONFORM" |
        command grep -qE '^\^?release\$?$'; then
        assert_true true "release scope present (regression guard for #409)"
    else
        assert_true false "release scope missing — chore(release): commits will fail the commit-msg hook"
    fi
}

test_scopes_are_anchored() {
    # Conform uses unanchored regex matching. Every entry must start with
    # `^` and end with `$`, otherwise short scopes leak (e.g. `op` would
    # match `feat(operation):`).
    local unanchored
    unanchored=$(yq eval '.policies[0].spec.conventional.scopes[]' "$CONFORM" |
        command grep -vE '^\^[^$]+\$$' || true)
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
    local allowed_anchored
    allowed_anchored=$(yq eval '.policies[0].spec.conventional.scopes[]' "$CONFORM")

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
        # Match against anchored entries: scope must equal one of the bare
        # names (after stripping ^ and $).
        if echo "$allowed_anchored" |
            command sed 's/^\^//; s/\$$//' |
            command grep -Fxq "$scope"; then
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

run_test test_yaml_parseable ".conform.yaml is valid YAML"
run_test test_scopes_non_empty "scopes list is non-empty"
run_test test_release_scope_present "release scope present (regression for #409)"
run_test test_scopes_are_anchored "every scope is anchored ^...\$"
run_test test_historical_scopes_covered ">=${HISTORICAL_COVERAGE_MIN}% of historical scopes are allowed"

generate_report
