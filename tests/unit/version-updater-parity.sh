#!/usr/bin/env bash
# Unit tests for parity between the version registry and the version updaters
#
# bin/check-versions.sh registers every tool whose version we track. For each
# of those, bin/lib/update-versions/updaters.sh must carry a matching `case`
# arm that knows how to rewrite the pin. A tool registered in the first but
# missing from the second hits the `*)` fallback: update-versions.sh reports it
# as skipped and the weekly auto-patch job stalls that tool at an old version.
#
# That gap went unnoticed until `hadolint` had drifted two minor versions
# (issue #781). These tests make the invariant enforceable at commit time
# rather than discoverable at the next upstream release.

set -euo pipefail

# Source test framework
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Version Updater Parity Tests"

CHECK_VERSIONS="$PROJECT_ROOT/bin/check-versions.sh"
UPDATERS="$PROJECT_ROOT/bin/lib/update-versions/updaters.sh"

# Tools deliberately registered without an updater case. Keep this EMPTY unless
# there is a real reason — an entry here silences the parity check for that
# tool, so each one needs a comment saying why it can never need a rewrite.
# Deliberately an explicit edit, not an inferred exemption.
INTENTIONALLY_UNHANDLED=()

# Extract the tool names registered in check-versions.sh's checker dispatch.
# Matches the `  <tool>) check_<fn> ...` arms; the `*)` catch-all does not
# match the [A-Za-z0-9._-] name class, so it is excluded naturally.
registered_tools() {
    command grep -oE '^[[:space:]]+([A-Za-z0-9._-]+)\) check_' "$CHECK_VERSIONS" |
        command sed -E 's/^[[:space:]]+//; s/\) check_//' |
        command sort -u
}

# Extract the case labels from updaters.sh, splitting `a|b)` alternations.
#
# Known limitation: this is the union of labels across all four file-type
# branches (Dockerfile / setup.sh / *.sh / ci.yml), so it would not catch a
# tool whose case exists but sits in the wrong branch. It does catch the actual
# failure mode this test exists for — no case at all — and mirrors the audit
# recorded in issue #781. Parsing the nested `case` blocks branch-by-branch was
# judged too brittle to be worth the extra coverage.
updater_cases() {
    command grep -oE '^[[:space:]]+([A-Za-z0-9._|-]+)\)$' "$UPDATERS" |
        command sed -E 's/^[[:space:]]+//; s/\)$//' |
        command tr '|' '\n' |
        command sort -u
}

# True when $1 appears as a whole line in the newline-separated list on stdin.
# Substring matching is wrong here: short tool names like `sd` occur inside
# longer ones (`shfmt`, `sccache`), so a substring check would report a missing
# case as present.
has_case() {
    updater_cases | command grep -qxF "$1"
}

# Registered tools that have no updater case, minus any intentional exclusions.
missing_updater_cases() {
    local excluded_list=""
    if [ "${#INTENTIONALLY_UNHANDLED[@]}" -gt 0 ]; then
        excluded_list=$(printf '%s\n' "${INTENTIONALLY_UNHANDLED[@]}" | command sort -u)
    fi
    command comm -23 <(registered_tools) <(updater_cases) |
        command grep -vxF "$excluded_list" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Test: the extraction itself works
#
# This guards the two tests below from passing vacuously. If either regex stops
# matching (a formatting change, a refactor of the dispatch), the parity check
# would compare two empty lists and report a clean bill of health forever. This
# assertion matters more than the parity result it protects.
# ---------------------------------------------------------------------------
test_extraction_is_not_vacuous() {
    local registered_count updater_count
    registered_count=$(registered_tools | command wc -l)
    updater_count=$(updater_cases | command wc -l)

    assert_greater_than "$registered_count" 50 \
        "check-versions.sh should register >50 tools (found $registered_count) — if this fails, the extraction regex broke and the parity test below is vacuous"

    assert_greater_than "$updater_count" 50 \
        "updaters.sh should define >50 cases (found $updater_count) — if this fails, the extraction regex broke and the parity test below is vacuous"
}

# ---------------------------------------------------------------------------
# Test: every registered tool has an updater case
# ---------------------------------------------------------------------------
test_every_registered_tool_has_updater_case() {
    local missing
    missing=$(missing_updater_cases)

    if [ -n "$missing" ]; then
        local joined
        joined=$(echo "$missing" | command tr '\n' ' ')
        tf_fail_assertion \
            "Tools registered in bin/check-versions.sh with no case in updaters.sh:" \
            "  $joined" \
            "Add a case for each in bin/lib/update-versions/updaters.sh, or these" \
            "tools will silently stall at their current versions on the next" \
            "upstream release (issue #781)."
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Test: hyperfine and hyperfine-cargo stay independent
#
# Two separate pins share a prefix: HYPERFINE_VERSION in dev-tools.sh and
# HYPERFINE_CARGO_VERSION in rust-dev.sh. A sloppy sed pattern in either case
# could rewrite the other's pin, so assert both cases exist and that the
# `hyperfine` arm never names the _CARGO_ variable.
# ---------------------------------------------------------------------------
test_hyperfine_cases_are_isolated() {
    assert_true "has_case hyperfine" \
        "updaters.sh should have a 'hyperfine' case (HYPERFINE_VERSION in dev-tools.sh)"
    assert_true "has_case hyperfine-cargo" \
        "updaters.sh should have a 'hyperfine-cargo' case (HYPERFINE_CARGO_VERSION in rust-dev.sh)"

    # Body of the `hyperfine)` arm, up to its terminating `;;`
    local hyperfine_body
    hyperfine_body=$(command sed -n '/^[[:space:]]*hyperfine)$/,/;;/p' "$UPDATERS")

    assert_not_empty "$hyperfine_body" \
        "Should be able to extract the 'hyperfine' case body from updaters.sh"
    assert_contains "$hyperfine_body" "HYPERFINE_VERSION" \
        "The 'hyperfine' case should rewrite HYPERFINE_VERSION"
    assert_not_contains "$hyperfine_body" "HYPERFINE_CARGO_VERSION" \
        "The 'hyperfine' case must NOT touch HYPERFINE_CARGO_VERSION (that belongs to 'hyperfine-cargo' in rust-dev.sh)"
}

# ---------------------------------------------------------------------------
# Test: the three tools named in issue #781 are covered
#
# A regression guard pinned to the specific tools the issue was filed for. The
# parity test above would catch these too, but naming them keeps the fix's
# intent legible if the generic check is ever weakened.
# ---------------------------------------------------------------------------
test_issue_781_tools_have_cases() {
    local tool
    for tool in hyperfine jsonc-parser sd; do
        assert_true "has_case $tool" \
            "updaters.sh should have a '$tool' case (issue #781)"
    done
}

run_test "test_extraction_is_not_vacuous" "Tool-name extraction finds a plausible number of tools"
run_test "test_every_registered_tool_has_updater_case" "Every tool in check-versions.sh has an updater case"
run_test "test_hyperfine_cases_are_isolated" "hyperfine and hyperfine-cargo cases stay independent"
run_test "test_issue_781_tools_have_cases" "hyperfine, jsonc-parser, and sd have updater cases"

# Generate report
generate_report
