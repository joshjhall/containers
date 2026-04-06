#!/usr/bin/env bash
# Contract validation for check-* and loop-* skill contracts
#
# Validates:
# - JSON examples in contract.md are valid JSON
# - check-* contract examples have all required finding-schema fields
# - loop-* contract examples have all required loop-report fields
# - Contract version field exists
# - Category slugs in contract.md match patterns.sh output categories
#
# Uses jq for JSON parsing. No external schema validation library needed.

set -euo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the test framework
source "$SCRIPT_DIR/../../framework.sh"

# Initialize the test framework
init_test_framework

# Key directories
TEMPLATES_DIR="$CONTAINERS_DIR/lib/features/templates/claude"
SKILLS_DIR="$TEMPLATES_DIR/skills"
SCHEMA_DIR="$SKILLS_DIR/codebase-audit"

# Define test suite
test_suite "Skill Contract Validation"

# --- Helper Functions ---

# Extract JSON from the last ```json code fence in a file
# Uses the last fence because contracts with multiple fences put the
# example finding last (earlier fences may contain sub-objects like certainty)
extract_json_from_markdown() {
    local file="$1"
    # Find all json fences, keep the last one
    /usr/bin/awk '
        /^```json$/ { in_fence=1; content=""; next }
        /^```$/ && in_fence { in_fence=0; last=content; next }
        in_fence { content = content (content ? "\n" : "") $0 }
        END { if (last) print last }
    ' "$file"
}

# Extract all category slugs from a contract.md (from the Categories table)
# Looks for backtick-wrapped slugs in table rows
extract_contract_categories() {
    local file="$1"
    command grep -oP '`\K[a-z][a-z0-9-]+(?=`)' "$file" \
        | command grep -v '^version$\|^deterministic$\|^heuristic$\|^llm$\|^finding-schema\|^compatible' \
        | command sort -u
}

# Extract category slugs from a patterns.sh script
extract_patterns_categories() {
    local file="$1"
    # Categories appear as quoted strings in printf/echo statements as the 3rd TSV field
    # Look for category-like strings (lowercase with hyphens) in quoted context
    command grep -oP '"[a-z][a-z0-9]+-[a-z][a-z0-9-]*"' "$file" \
        | command sed 's/"//g' \
        | command sort -u
}

# Required fields for a finding (from finding-schema.md)
FINDING_REQUIRED_FIELDS="id category severity title description file line_start line_end evidence suggestion effort tags related_files certainty"

# Required fields for a loop report
LOOP_REQUIRED_FIELDS="loop status changes blockers_resolved blockers_remaining tests_passing commit"

# --- Schema File Tests ---

# Test: finding-schema.schema.json exists and is valid JSON
test_finding_schema_valid() {
    local schema_file="$SCHEMA_DIR/finding-schema.schema.json"
    assert_file_exists "$schema_file" "finding-schema.schema.json missing"

    local result
    result=$(jq empty "$schema_file" 2>&1) || true
    assert_true "jq empty '$schema_file' 2>/dev/null" \
        "finding-schema.schema.json is not valid JSON: $result"
}

# Test: loop-report.schema.json exists and is valid JSON
test_loop_report_schema_valid() {
    local schema_file="$SCHEMA_DIR/loop-report.schema.json"
    assert_file_exists "$schema_file" "loop-report.schema.json missing"

    local result
    result=$(jq empty "$schema_file" 2>&1) || true
    assert_true "jq empty '$schema_file' 2>/dev/null" \
        "loop-report.schema.json is not valid JSON: $result"
}

# --- check-* Contract Tests ---

# Test: Every check-* contract.md has valid JSON example
test_check_contract_json_valid() {
    local skill_dir
    for skill_dir in "$SKILLS_DIR"/check-*/; do
        [ -d "$skill_dir" ] || continue
        local skill_name
        skill_name="$(/usr/bin/basename "$skill_dir")"
        local contract_file="$skill_dir/contract.md"
        [ -f "$contract_file" ] || continue

        local json
        json="$(extract_json_from_markdown "$contract_file")"
        assert_not_empty "$json" "check-* skill $skill_name: no JSON found in contract.md"

        # Validate it's parseable JSON
        local tmpfile
        tmpfile="$(/usr/bin/mktemp)"
        echo "$json" > "$tmpfile"
        assert_true "jq empty '$tmpfile' 2>/dev/null" \
            "check-* skill $skill_name: contract.md JSON is not valid"
        /usr/bin/rm -f "$tmpfile"
    done
}

# Test: check-* contract JSON examples have all required finding fields
test_check_contract_required_fields() {
    local skill_dir
    for skill_dir in "$SKILLS_DIR"/check-*/; do
        [ -d "$skill_dir" ] || continue
        local skill_name
        skill_name="$(/usr/bin/basename "$skill_dir")"
        local contract_file="$skill_dir/contract.md"
        [ -f "$contract_file" ] || continue

        local json
        json="$(extract_json_from_markdown "$contract_file")"
        [ -z "$json" ] && continue

        local tmpfile
        tmpfile="$(/usr/bin/mktemp)"
        echo "$json" > "$tmpfile"

        # Check each required field exists in the JSON
        local field
        for field in $FINDING_REQUIRED_FIELDS; do
            assert_true "jq -e 'has(\"$field\")' '$tmpfile' >/dev/null 2>&1" \
                "check-* skill $skill_name: contract example missing required field '$field'"
        done

        /usr/bin/rm -f "$tmpfile"
    done
}

# Test: check-* contract JSON severity values are valid enums
test_check_contract_enum_values() {
    local skill_dir
    for skill_dir in "$SKILLS_DIR"/check-*/; do
        [ -d "$skill_dir" ] || continue
        local skill_name
        skill_name="$(/usr/bin/basename "$skill_dir")"
        local contract_file="$skill_dir/contract.md"
        [ -f "$contract_file" ] || continue

        local json
        json="$(extract_json_from_markdown "$contract_file")"
        [ -z "$json" ] && continue

        local tmpfile
        tmpfile="$(/usr/bin/mktemp)"
        echo "$json" > "$tmpfile"

        # Validate severity enum
        local severity
        severity="$(jq -r '.severity // empty' "$tmpfile" 2>/dev/null)"
        if [ -n "$severity" ]; then
            assert_true "echo '$severity' | command grep -qE '^(critical|high|medium|low)$'" \
                "check-* skill $skill_name: invalid severity '$severity'"
        fi

        # Validate effort enum
        local effort
        effort="$(jq -r '.effort // empty' "$tmpfile" 2>/dev/null)"
        if [ -n "$effort" ]; then
            assert_true "echo '$effort' | command grep -qE '^(trivial|small|medium|large)$'" \
                "check-* skill $skill_name: invalid effort '$effort'"
        fi

        # Validate certainty.level enum
        local cert_level
        cert_level="$(jq -r '.certainty.level // empty' "$tmpfile" 2>/dev/null)"
        if [ -n "$cert_level" ]; then
            assert_true "echo '$cert_level' | command grep -qE '^(CRITICAL|HIGH|MEDIUM|LOW)$'" \
                "check-* skill $skill_name: invalid certainty level '$cert_level'"
        fi

        # Validate certainty.method enum
        local cert_method
        cert_method="$(jq -r '.certainty.method // empty' "$tmpfile" 2>/dev/null)"
        if [ -n "$cert_method" ]; then
            assert_true "echo '$cert_method' | command grep -qE '^(deterministic|heuristic|llm)$'" \
                "check-* skill $skill_name: invalid certainty method '$cert_method'"
        fi

        # Validate certainty.confidence range
        local cert_conf
        cert_conf="$(jq -r '.certainty.confidence // empty' "$tmpfile" 2>/dev/null)"
        if [ -n "$cert_conf" ]; then
            assert_true "echo '$cert_conf' | command grep -qE '^[01]\\.?[0-9]*$'" \
                "check-* skill $skill_name: certainty confidence '$cert_conf' out of 0-1 range"
        fi

        /usr/bin/rm -f "$tmpfile"
    done
}

# Test: check-* contract version exists
test_check_contract_version() {
    local skill_dir
    for skill_dir in "$SKILLS_DIR"/check-*/; do
        [ -d "$skill_dir" ] || continue
        local skill_name
        skill_name="$(/usr/bin/basename "$skill_dir")"
        local contract_file="$skill_dir/contract.md"
        [ -f "$contract_file" ] || continue

        assert_true "command grep -q 'version:' '$contract_file'" \
            "check-* skill $skill_name: contract.md missing version field"
    done
}

# --- loop-* Contract Tests ---

# Test: Every loop-* contract.md has valid JSON example
test_loop_contract_json_valid() {
    local skill_dir
    for skill_dir in "$SKILLS_DIR"/loop-*/; do
        [ -d "$skill_dir" ] || continue
        local skill_name
        skill_name="$(/usr/bin/basename "$skill_dir")"
        local contract_file="$skill_dir/contract.md"
        [ -f "$contract_file" ] || continue

        local json
        json="$(extract_json_from_markdown "$contract_file")"
        assert_not_empty "$json" "loop-* skill $skill_name: no JSON found in contract.md"

        local tmpfile
        tmpfile="$(/usr/bin/mktemp)"
        echo "$json" > "$tmpfile"
        assert_true "jq empty '$tmpfile' 2>/dev/null" \
            "loop-* skill $skill_name: contract.md JSON is not valid"
        /usr/bin/rm -f "$tmpfile"
    done
}

# Test: loop-* contract JSON examples have all required loop-report fields
test_loop_contract_required_fields() {
    local skill_dir
    for skill_dir in "$SKILLS_DIR"/loop-*/; do
        [ -d "$skill_dir" ] || continue
        local skill_name
        skill_name="$(/usr/bin/basename "$skill_dir")"
        local contract_file="$skill_dir/contract.md"
        [ -f "$contract_file" ] || continue

        local json
        json="$(extract_json_from_markdown "$contract_file")"
        [ -z "$json" ] && continue

        local tmpfile
        tmpfile="$(/usr/bin/mktemp)"
        echo "$json" > "$tmpfile"

        local field
        for field in $LOOP_REQUIRED_FIELDS; do
            assert_true "jq -e 'has(\"$field\")' '$tmpfile' >/dev/null 2>&1" \
                "loop-* skill $skill_name: contract example missing required field '$field'"
        done

        /usr/bin/rm -f "$tmpfile"
    done
}

# Test: loop-* contract version exists
test_loop_contract_version() {
    local skill_dir
    for skill_dir in "$SKILLS_DIR"/loop-*/; do
        [ -d "$skill_dir" ] || continue
        local skill_name
        skill_name="$(/usr/bin/basename "$skill_dir")"
        local contract_file="$skill_dir/contract.md"
        [ -f "$contract_file" ] || continue

        assert_true "command grep -q 'version:' '$contract_file'" \
            "loop-* skill $skill_name: contract.md missing version field"
    done
}

# --- Category Cross-Check Tests ---

# Test: check-* contract categories match patterns.sh categories
test_category_cross_check() {
    local skill_dir
    for skill_dir in "$SKILLS_DIR"/check-*/; do
        [ -d "$skill_dir" ] || continue
        local skill_name
        skill_name="$(/usr/bin/basename "$skill_dir")"
        local contract_file="$skill_dir/contract.md"
        local patterns_file="$skill_dir/patterns.sh"

        # Both files must exist for cross-check
        [ -f "$contract_file" ] || continue
        [ -f "$patterns_file" ] || continue

        local contract_cats patterns_cats
        contract_cats="$(extract_contract_categories "$contract_file")"
        patterns_cats="$(extract_patterns_categories "$patterns_file")"

        # Skip if we couldn't extract categories from either
        [ -z "$contract_cats" ] && continue
        [ -z "$patterns_cats" ] && continue

        # Every patterns.sh category should appear in the contract
        local cat
        while IFS= read -r cat; do
            [ -z "$cat" ] && continue
            assert_true "echo '$contract_cats' | command grep -qF '$cat'" \
                "check-* skill $skill_name: patterns.sh outputs category '$cat' not declared in contract.md"
        done <<< "$patterns_cats"
    done
}

# --- Run All Tests ---

run_test test_finding_schema_valid "finding-schema.schema.json is valid JSON"
run_test test_loop_report_schema_valid "loop-report.schema.json is valid JSON"
run_test test_check_contract_json_valid "check-* contract.md JSON examples are valid"
run_test test_check_contract_required_fields "check-* contract examples have all required fields"
run_test test_check_contract_enum_values "check-* contract enum values are valid"
run_test test_check_contract_version "check-* contracts have version field"
run_test test_loop_contract_json_valid "loop-* contract.md JSON examples are valid"
run_test test_loop_contract_required_fields "loop-* contract examples have all required fields"
run_test test_loop_contract_version "loop-* contracts have version field"
run_test test_category_cross_check "check-* contract categories match patterns.sh"

# Generate test report
generate_report
