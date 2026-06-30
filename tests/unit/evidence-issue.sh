#!/usr/bin/env bash
# Unit tests for validate_issue_inputs() and open_or_update_tracking_issue() in
# bin/lib/evidence-issue.sh — the evidence fail-row tracking-issue logic
# extracted from .github/workflows/evidence-run.yml's "Open or update tracking
# issue on fail row" step (#653, logic from #652).
#
# These guards are the primary injection defense for the gh --search title and
# the issue body: three anchored input regexes (tool slug, version, tuple), a
# numeric guard on the captured EXISTING issue number, and the search-or-create
# branch. None had coverage before this suite.
#
# Offline: a fake `gh` is written to $TEST_TEMP_DIR/gh and injected via the
# helper's `GH` override (an absolute path — PATH-shadowing is unreliable, the
# shell re-initializes PATH on each bash startup; same idiom as
# dispatch-evidence.sh). The stub reads EXISTING_NUMBER from its environment to
# script what `gh issue list ... --jq` returns (a number / empty / a corrupt
# value) and records each subcommand to $GH_CALLS so tests assert which branch
# ran. `gh label create` always exits 0.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../framework.sh
source "$SCRIPT_DIR/../framework.sh"

SKIP_DOCKER_CHECK=true init_test_framework

test_suite "bin/lib/evidence-issue.sh tracking-issue"

# shellcheck source=../../bin/lib/evidence-issue.sh
source "$PROJECT_ROOT/bin/lib/evidence-issue.sh"

# Write a fake `gh` to an absolute path. It logs every invocation (subcommand +
# args, including --body-file content) to $GH_CALLS so tests can assert which
# branch ran. `issue list` echoes $EXISTING_NUMBER (the helper's `--jq` capture);
# everything else — label create, issue edit/comment/create — just logs+exits 0.
install_gh_stub() {
    GH_STUB="$TEST_TEMP_DIR/gh"
    GH_CALLS="$TEST_TEMP_DIR/gh-calls.log"
    command rm -f "$GH_CALLS"
    command cat >"$GH_STUB" <<'STUB'
#!/usr/bin/env bash
# Record the full argv on one line.
command printf '%s\n' "$*" >>"$GH_CALLS"
sub="$1 ${2:-}"
case "$sub" in
    "issue list")
        # Mimic `--jq '.[0].number // empty'`: print whatever the test scripted
        # (a number, a corrupt token, or nothing for the empty/no-match case).
        command printf '%s' "${EXISTING_NUMBER:-}"
        ;;
    "issue edit"|"issue comment"|"issue create"|"label create")
        # If a --body-file is present, append its content so tests can inspect
        # the heredoc body bytes that reached gh.
        prev=""
        for a in "$@"; do
            if [ "$prev" = "--body-file" ] && [ -f "$a" ]; then
                command printf 'BODY<<%s>>\n' "$(command cat "$a")" >>"$GH_CALLS"
            fi
            prev="$a"
        done
        ;;
esac
exit 0
STUB
    command chmod +x "$GH_STUB"
}

# --- validate_issue_inputs tests -------------------------------------------

test_valid_inputs_pass_regexes() {
    local rc=0
    validate_issue_inputs "rust" "1.95.0" "debian-12-amd64" || rc=$?
    assert_equals "0" "$rc" "well-formed tool/version/tuple pass all three regexes"
}

test_reject_tool_metachar() {
    local rc=0
    validate_issue_inputs "rust;rm" "1.95.0" "debian-12-amd64" 2>/dev/null || rc=$?
    assert_equals "1" "$rc" "a shell metacharacter in the tool slug is rejected"
}

test_reject_tool_uppercase() {
    local rc=0
    validate_issue_inputs "Rust" "1.95.0" "debian-12-amd64" 2>/dev/null || rc=$?
    assert_equals "1" "$rc" "an uppercase tool slug is rejected (tool regex is lowercase)"
}

test_reject_tool_leading_dash() {
    local rc=0
    validate_issue_inputs "-rust" "1.95.0" "debian-12-amd64" 2>/dev/null || rc=$?
    assert_equals "1" "$rc" "a leading-dash tool slug is rejected"
}

test_reject_version_metachar() {
    local rc=0
    validate_issue_inputs "rust" '1.0$(x)' "debian-12-amd64" 2>/dev/null || rc=$?
    assert_equals "1" "$rc" "command-substitution metachars in the version are rejected"
}

test_reject_tuple_four_tokens() {
    local rc=0
    validate_issue_inputs "rust" "1.95.0" "debian-12-amd64-x" 2>/dev/null || rc=$?
    assert_equals "1" "$rc" "a four-token tuple is rejected (regex anchors three segments)"
}

test_reject_tuple_with_space() {
    local rc=0
    # A space lets a gh-search operator (in:title) ride along — must be rejected.
    validate_issue_inputs "rust" "1.95.0" "debian-12-amd64 in:title" 2>/dev/null || rc=$?
    assert_equals "1" "$rc" "a tuple carrying a space / search operator is rejected"
}

# --- open_or_update_tracking_issue tests -----------------------------------

# Run the helper with the stub injected by absolute path, EXISTING_NUMBER
# scripting the `issue list` capture. Captures rc via `|| rc=$?` so a `return 1`
# under set -e is observable instead of aborting the test.
run_open() {
    local existing="$1"
    OPEN_RC=0
    GH="$GH_STUB" EXISTING_NUMBER="$existing" GH_CALLS="$GH_CALLS" \
        open_or_update_tracking_issue \
        "rust" "1.95.0" "debian-12-amd64" "verify" "https://example.com/run/1" \
        >/dev/null 2>"$TEST_TEMP_DIR/open-err" || OPEN_RC=$?
}

test_existing_numeric_guard_rejects_corrupt() {
    install_gh_stub
    run_open "12x"
    assert_equals "1" "$OPEN_RC" "a corrupt EXISTING number makes the helper return 1"
    local err
    err="$(command cat "$TEST_TEMP_DIR/open-err")"
    assert_contains "$err" "Unexpected issue number" "stderr explains the corrupt number"
    local calls
    calls="$(command cat "$GH_CALLS")"
    assert_not_contains "$calls" "issue create" "no issue is created when the number is corrupt"
    assert_not_contains "$calls" "issue edit" "no issue is edited when the number is corrupt"
}

test_update_path() {
    install_gh_stub
    run_open "42"
    assert_equals "0" "$OPEN_RC" "the update path returns 0"
    local calls
    calls="$(command cat "$GH_CALLS")"
    assert_contains "$calls" "issue edit 42" "an existing number takes the edit path"
    assert_contains "$calls" "issue comment 42" "the update path also posts a comment"
    assert_not_contains "$calls" "issue create" "the update path must NOT create a new issue"
}

test_create_path() {
    install_gh_stub
    run_open ""
    assert_equals "0" "$OPEN_RC" "the create path returns 0"
    local calls
    calls="$(command cat "$GH_CALLS")"
    assert_contains "$calls" "issue create" "an empty EXISTING takes the create path"
    assert_contains "$calls" "--label severity/high" "create carries the severity/high label"
    assert_contains "$calls" "--label type/bug" "create carries the type/bug label"
    assert_contains "$calls" "--label audit/regression" "create carries the audit/regression label"
    assert_not_contains "$calls" "issue edit" "the create path must NOT edit an existing issue"
}

# --- Run -------------------------------------------------------------------

run_test test_valid_inputs_pass_regexes "well-formed inputs pass all three regexes"
run_test test_reject_tool_metachar "tool with a shell metacharacter is rejected"
run_test test_reject_tool_uppercase "uppercase tool slug is rejected"
run_test test_reject_tool_leading_dash "leading-dash tool slug is rejected"
run_test test_reject_version_metachar "version with command-substitution is rejected"
run_test test_reject_tuple_four_tokens "four-token tuple is rejected"
run_test test_reject_tuple_with_space "tuple with a space / search operator is rejected"
run_test test_existing_numeric_guard_rejects_corrupt "corrupt EXISTING number → rc 1, no create/edit"
run_test test_update_path "EXISTING numeric → edit + comment, no create"
run_test test_create_path "EXISTING empty → create with all three labels, no edit"

generate_report
