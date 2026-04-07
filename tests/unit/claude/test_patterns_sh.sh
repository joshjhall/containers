#!/usr/bin/env bash
# Golden fixture tests for all 14 patterns.sh scripts
#
# Each patterns.sh is run against a minimal fixture file designed to trigger
# at least one known detection. Tests validate:
# - Exit code 0
# - Non-empty output (fixture triggers detection)
# - Valid TSV format (5 tab-separated columns per line)
# - Expected category appears in output
#
# Edge cases: empty file list, non-existent files, binary files.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../framework.sh"
init_test_framework

SKILLS_DIR="$CONTAINERS_DIR/lib/features/templates/claude/skills"
FIXTURES_DIR="$CONTAINERS_DIR/tests/fixtures/claude/patterns"

test_suite "Patterns.sh Golden Fixture Tests"

# ---------------------------------------------------------------------------
# Helper: validate TSV output format (5 tab-separated columns per line)
# ---------------------------------------------------------------------------
validate_tsv_output() {
    local output="$1"
    local context="$2"

    if [ -z "$output" ]; then
        fail_test "$context: expected non-empty output"
        return 1
    fi

    local line_num=0
    while IFS= read -r line; do
        line_num=$((line_num + 1))
        [ -z "$line" ] && continue

        # Count tab-separated fields
        local field_count
        field_count=$(/usr/bin/printf '%s' "$line" | /usr/bin/awk -F'\t' '{print NF}')
        if [ "$field_count" -ne 5 ]; then
            fail_test "$context: line $line_num has $field_count columns, expected 5"
            return 1
        fi
    done <<< "$output"

    return 0
}

# ---------------------------------------------------------------------------
# Helper: assert a category appears in TSV output (column 3)
# ---------------------------------------------------------------------------
assert_category_in_output() {
    local output="$1"
    local expected_category="$2"
    local context="$3"

    if ! /usr/bin/printf '%s' "$output" | /usr/bin/awk -F'\t' '{print $3}' | /usr/bin/grep -q "^${expected_category}$"; then
        fail_test "$context: expected category '$expected_category' not found in output"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Helper: run a standard patterns.sh test (single file-list argument)
#
# Many patterns.sh scripts skip files whose paths contain "test", "fixture",
# "spec", etc. To avoid false negatives, this helper copies the fixture to a
# temp path that won't match those skip patterns.
# ---------------------------------------------------------------------------
run_patterns_test() {
    local script="$1"
    local fixture="$2"
    local expected_category="$3"
    local label="$4"

    local tmpdir
    tmpdir=$(/usr/bin/mktemp -d)

    # Copy fixture to a clean path (no "test"/"fixture"/"spec" in name)
    local clean_name
    clean_name=$(/usr/bin/basename "$fixture" | /usr/bin/sed 's/fixture/sample/g; s/test/src/g')
    /usr/bin/cp "$fixture" "${tmpdir}/${clean_name}"

    # Create file list
    local file_list="${tmpdir}/filelist.txt"
    /usr/bin/printf '%s\n' "${tmpdir}/${clean_name}" > "$file_list"

    # Run the script
    local output exit_code
    output=$("$script" "$file_list" 2>/dev/null) && exit_code=0 || exit_code=$?

    assert_equals "0" "$exit_code" "$label: exit code"
    validate_tsv_output "$output" "$label"
    assert_category_in_output "$output" "$expected_category" "$label"

    /usr/bin/rm -rf "$tmpdir"
}

# ===========================================================================
# 1. check-security
# ===========================================================================
test_check_security() {
    run_patterns_test \
        "$SKILLS_DIR/check-security/patterns.sh" \
        "$FIXTURES_DIR/security_fixture.py" \
        "hardcoded-secret" \
        "check-security"
}
run_test test_check_security "check-security detects hardcoded secrets"

# ===========================================================================
# 2. check-code-health
# ===========================================================================
test_check_code_health() {
    run_patterns_test \
        "$SKILLS_DIR/check-code-health/patterns.sh" \
        "$FIXTURES_DIR/code_health_fixture.py" \
        "tech-debt-marker" \
        "check-code-health"
}
run_test test_check_code_health "check-code-health detects tech debt markers"

# ===========================================================================
# 3. check-docs-staleness
# ===========================================================================
test_check_docs_staleness() {
    run_patterns_test \
        "$SKILLS_DIR/check-docs-staleness/patterns.sh" \
        "$FIXTURES_DIR/docs_staleness_fixture.md" \
        "expired-date" \
        "check-docs-staleness"
}
run_test test_check_docs_staleness "check-docs-staleness detects expired dates"

# ===========================================================================
# 4. check-docs-deadlinks
# ===========================================================================
test_check_docs_deadlinks() {
    run_patterns_test \
        "$SKILLS_DIR/check-docs-deadlinks/patterns.sh" \
        "$FIXTURES_DIR/docs_deadlinks_fixture.md" \
        "broken-relative-link" \
        "check-docs-deadlinks"
}
run_test test_check_docs_deadlinks "check-docs-deadlinks detects broken relative links"

# ===========================================================================
# 5. check-docs-examples
# ===========================================================================
test_check_docs_examples() {
    run_patterns_test \
        "$SKILLS_DIR/check-docs-examples/patterns.sh" \
        "$FIXTURES_DIR/docs_examples_fixture.md" \
        "broken-example" \
        "check-docs-examples"
}
run_test test_check_docs_examples "check-docs-examples detects broken code examples"

# ===========================================================================
# 6. check-docs-missing-api
# ===========================================================================
test_check_docs_missing_api() {
    run_patterns_test \
        "$SKILLS_DIR/check-docs-missing-api/patterns.sh" \
        "$FIXTURES_DIR/docs_missing_api_fixture.py" \
        "undocumented-public-api" \
        "check-docs-missing-api"
}
run_test test_check_docs_missing_api "check-docs-missing-api detects undocumented public APIs"

# ===========================================================================
# 7. check-docs-organization
# ===========================================================================
test_check_docs_organization() {
    # This script checks project root for missing files and directories
    # without READMEs, so we create a temp project structure
    local tmpdir
    tmpdir=$(/usr/bin/mktemp -d)

    # Create a directory with 6+ files but no README
    local noreadme_dir="${tmpdir}/src/components"
    /usr/bin/mkdir -p "$noreadme_dir"
    for i in 1 2 3 4 5 6; do
        /usr/bin/touch "${noreadme_dir}/file${i}.py"
    done

    # Create a dummy file list (script uses git root, not file list contents,
    # for org checks — but it still needs a valid file list argument)
    local file_list="${tmpdir}/filelist.txt"
    /usr/bin/printf '%s\n' "${noreadme_dir}/file1.py" > "$file_list"

    # Create minimal git repo so git rev-parse works
    (cd "$tmpdir" && /usr/bin/git init -q 2>/dev/null)

    local output exit_code
    output=$(cd "$tmpdir" && "$SKILLS_DIR/check-docs-organization/patterns.sh" "$file_list" 2>/dev/null) && exit_code=0 || exit_code=$?

    assert_equals "0" "$exit_code" "check-docs-organization: exit code"
    validate_tsv_output "$output" "check-docs-organization"
    # Should detect missing README.md at root
    assert_category_in_output "$output" "missing-root-doc" "check-docs-organization"

    /usr/bin/rm -rf "$tmpdir"
}
run_test test_check_docs_organization "check-docs-organization detects missing root docs"

# ===========================================================================
# 8. check-ai-config
# ===========================================================================
test_check_ai_config() {
    # check-ai-config needs an agents/ directory structure
    local tmpdir
    tmpdir=$(/usr/bin/mktemp -d)

    # Create agent directory structure with a bad agent file
    local agent_dir="${tmpdir}/agents/broken-agent"
    /usr/bin/mkdir -p "$agent_dir"
    /usr/bin/cp "$FIXTURES_DIR/ai_config_agent_fixture.md" "${agent_dir}/broken-agent.md"

    local file_list="${tmpdir}/filelist.txt"
    /usr/bin/printf '%s\n' "${agent_dir}/broken-agent.md" > "$file_list"

    local output exit_code
    output=$("$SKILLS_DIR/check-ai-config/patterns.sh" "$file_list" 2>/dev/null) && exit_code=0 || exit_code=$?

    assert_equals "0" "$exit_code" "check-ai-config: exit code"
    validate_tsv_output "$output" "check-ai-config"
    assert_category_in_output "$output" "agent-frontmatter" "check-ai-config"

    /usr/bin/rm -rf "$tmpdir"
}
run_test test_check_ai_config "check-ai-config detects missing agent frontmatter"

# ===========================================================================
# 9. loop-make-it-work
# ===========================================================================
test_loop_make_it_work() {
    run_patterns_test \
        "$SKILLS_DIR/loop-make-it-work/patterns.sh" \
        "$FIXTURES_DIR/make_it_work_fixture.py" \
        "stub-detected" \
        "loop-make-it-work"
}
run_test test_loop_make_it_work "loop-make-it-work detects stubs and placeholders"

# ===========================================================================
# 10. loop-make-it-tested
# ===========================================================================
test_loop_make_it_tested() {
    run_patterns_test \
        "$SKILLS_DIR/loop-make-it-tested/patterns.sh" \
        "$FIXTURES_DIR/make_it_tested_fixture.py" \
        "missing-test-file" \
        "loop-make-it-tested"
}
run_test test_loop_make_it_tested "loop-make-it-tested detects missing test files"

# ===========================================================================
# 11. loop-make-it-documented
# ===========================================================================
test_loop_make_it_documented() {
    run_patterns_test \
        "$SKILLS_DIR/loop-make-it-documented/patterns.sh" \
        "$FIXTURES_DIR/make_it_documented_fixture.py" \
        "undocumented-public-function" \
        "loop-make-it-documented"
}
run_test test_loop_make_it_documented "loop-make-it-documented detects undocumented functions"

# ===========================================================================
# 12. loop-make-it-right
# ===========================================================================
test_loop_make_it_right() {
    run_patterns_test \
        "$SKILLS_DIR/loop-make-it-right/patterns.sh" \
        "$FIXTURES_DIR/make_it_right_fixture.py" \
        "long-function" \
        "loop-make-it-right"
}
run_test test_loop_make_it_right "loop-make-it-right detects long functions"

# ===========================================================================
# 13. loop-make-it-secure
# ===========================================================================
test_loop_make_it_secure() {
    run_patterns_test \
        "$SKILLS_DIR/loop-make-it-secure/patterns.sh" \
        "$FIXTURES_DIR/make_it_secure_fixture.py" \
        "dangerous-function" \
        "loop-make-it-secure"
}
run_test test_loop_make_it_secure "loop-make-it-secure detects dangerous functions"

# ===========================================================================
# 14. drift-detect
# ===========================================================================
test_drift_detect() {
    local output exit_code
    output=$("$SKILLS_DIR/drift-detect/patterns.sh" \
        "$FIXTURES_DIR/drift_detect_actual.txt" \
        "$FIXTURES_DIR/drift_detect_planned.txt" 2>/dev/null) && exit_code=0 || exit_code=$?

    assert_equals "0" "$exit_code" "drift-detect: exit code"
    validate_tsv_output "$output" "drift-detect"
    assert_category_in_output "$output" "planned-not-touched" "drift-detect"
    assert_category_in_output "$output" "unplanned-modification" "drift-detect"
}
run_test test_drift_detect "drift-detect detects planned-not-touched and unplanned modifications"

# ===========================================================================
# Edge case: empty file list
# ===========================================================================
test_edge_empty_file_list() {
    local tmpdir
    tmpdir=$(/usr/bin/mktemp -d)
    /usr/bin/touch "${tmpdir}/empty.txt"

    local output exit_code
    output=$("$SKILLS_DIR/check-security/patterns.sh" "${tmpdir}/empty.txt" 2>/dev/null) && exit_code=0 || exit_code=$?

    assert_equals "0" "$exit_code" "empty-file-list: exit code"
    assert_empty "$output" "empty-file-list: should produce no output"

    /usr/bin/rm -rf "$tmpdir"
}
run_test test_edge_empty_file_list "Empty file list produces no output"

# ===========================================================================
# Edge case: non-existent file in list
# ===========================================================================
test_edge_nonexistent_file() {
    local tmpdir
    tmpdir=$(/usr/bin/mktemp -d)
    /usr/bin/printf '%s\n' "/nonexistent/path/foo.py" > "${tmpdir}/filelist.txt"

    local output exit_code
    output=$("$SKILLS_DIR/check-code-health/patterns.sh" "${tmpdir}/filelist.txt" 2>/dev/null) && exit_code=0 || exit_code=$?

    assert_equals "0" "$exit_code" "nonexistent-file: exit code (should skip gracefully)"
    assert_empty "$output" "nonexistent-file: should produce no output"

    /usr/bin/rm -rf "$tmpdir"
}
run_test test_edge_nonexistent_file "Non-existent file in list is skipped gracefully"

# ===========================================================================
# Edge case: binary file in list
# ===========================================================================
test_edge_binary_file() {
    local tmpdir
    tmpdir=$(/usr/bin/mktemp -d)
    # Create a small binary file
    /usr/bin/printf '\x00\x01\x02\x03\x04\x05' > "${tmpdir}/binary.py"
    /usr/bin/printf '%s\n' "${tmpdir}/binary.py" > "${tmpdir}/filelist.txt"

    local output exit_code
    output=$("$SKILLS_DIR/check-code-health/patterns.sh" "${tmpdir}/filelist.txt" 2>/dev/null) && exit_code=0 || exit_code=$?

    assert_equals "0" "$exit_code" "binary-file: exit code (should not crash)"

    /usr/bin/rm -rf "$tmpdir"
}
run_test test_edge_binary_file "Binary file does not crash patterns.sh"

# ===========================================================================
# Generate report
# ===========================================================================
generate_report
