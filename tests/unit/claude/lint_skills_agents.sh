#!/usr/bin/env bash
# Structural lint for Claude Code agent and skill definitions
#
# Validates:
# - Every skill dir has SKILL.md + metadata.yml
# - Every agent dir has <name>.md with valid frontmatter
# - check-*/loop-*/context-* skills have required companion files
# - Cross-references between docs and filesystem
# - patterns.sh files are executable
#
# No Docker required — pure filesystem checks against templates directory.

set -euo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the test framework
source "$SCRIPT_DIR/../../framework.sh"

# Initialize the test framework
init_test_framework

# Key directories
TEMPLATES_DIR="$CONTAINERS_DIR/lib/features/templates/claude"
AGENTS_DIR="$TEMPLATES_DIR/agents"
SKILLS_DIR="$TEMPLATES_DIR/skills"
DOCS_FILE="$CONTAINERS_DIR/docs/claude-code/skills-and-agents.md"

# Define test suite
test_suite "Claude Agent/Skill Structural Lint"

# Valid values for frontmatter fields
VALID_MODELS="opus sonnet haiku"
VALID_TOOLS="Read Write Edit Bash Grep Glob Task WebFetch WebSearch"

# --- Helper Functions ---

# Extract YAML frontmatter value from a file
# Usage: get_frontmatter_field <file> <field>
get_frontmatter_field() {
    local file="$1"
    local field="$2"
    # Read between --- delimiters, find the field
    /usr/bin/sed -n '/^---$/,/^---$/p' "$file" |
        command grep "^${field}:" |
        command sed "s/^${field}:[[:space:]]*//"
}

# Check if a value is in a space-separated list
# Usage: is_valid_value <value> <list>
is_valid_value() {
    local value="$1"
    local list="$2"
    local item
    for item in $list; do
        [ "$value" = "$item" ] && return 0
    done
    return 1
}

# --- Agent Tests ---

# Test: Every agent directory has a correctly named .md file
test_agent_files_exist() {
    local agent_dir
    for agent_dir in "$AGENTS_DIR"/*/; do
        local agent_name
        agent_name="$(/usr/bin/basename "$agent_dir")"
        local agent_file="$agent_dir/${agent_name}.md"
        assert_file_exists "$agent_file" "Agent $agent_name missing ${agent_name}.md"
    done
}

# Test: Every agent has required frontmatter fields
test_agent_frontmatter_fields() {
    local agent_dir
    for agent_dir in "$AGENTS_DIR"/*/; do
        local agent_name
        agent_name="$(/usr/bin/basename "$agent_dir")"
        local agent_file="$agent_dir/${agent_name}.md"
        [ -f "$agent_file" ] || continue

        # Check required fields exist
        local name_val description_val tools_val model_val
        name_val="$(get_frontmatter_field "$agent_file" "name")"
        description_val="$(get_frontmatter_field "$agent_file" "description")"
        tools_val="$(get_frontmatter_field "$agent_file" "tools")"
        model_val="$(get_frontmatter_field "$agent_file" "model")"

        assert_not_empty "$name_val" "Agent $agent_name: missing 'name' in frontmatter"
        assert_not_empty "$description_val" "Agent $agent_name: missing 'description' in frontmatter"
        assert_not_empty "$tools_val" "Agent $agent_name: missing 'tools' in frontmatter"
        assert_not_empty "$model_val" "Agent $agent_name: missing 'model' in frontmatter"

        # Validate name matches directory
        assert_equals "$name_val" "$agent_name" "Agent $agent_name: frontmatter name mismatch"
    done
}

# Test: Agent model values are valid
test_agent_model_values() {
    local agent_dir
    for agent_dir in "$AGENTS_DIR"/*/; do
        local agent_name
        agent_name="$(/usr/bin/basename "$agent_dir")"
        local agent_file="$agent_dir/${agent_name}.md"
        [ -f "$agent_file" ] || continue

        local model_val
        model_val="$(get_frontmatter_field "$agent_file" "model")"
        [ -z "$model_val" ] && continue

        if ! is_valid_value "$model_val" "$VALID_MODELS"; then
            assert_true false "Agent $agent_name: invalid model '$model_val' (expected: $VALID_MODELS)"
        fi
    done
}

# Test: Agent tools values are valid
test_agent_tool_values() {
    local agent_dir
    for agent_dir in "$AGENTS_DIR"/*/; do
        local agent_name
        agent_name="$(/usr/bin/basename "$agent_dir")"
        local agent_file="$agent_dir/${agent_name}.md"
        [ -f "$agent_file" ] || continue

        local tools_val
        tools_val="$(get_frontmatter_field "$agent_file" "tools")"
        [ -z "$tools_val" ] && continue

        # Split comma-separated tools and validate each
        local tool
        while IFS=',' read -ra TOOLS_ARRAY; do
            for tool in "${TOOLS_ARRAY[@]}"; do
                tool="$(echo "$tool" | command sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
                [ -z "$tool" ] && continue
                if ! is_valid_value "$tool" "$VALID_TOOLS"; then
                    assert_true false "Agent $agent_name: invalid tool '$tool' (expected: $VALID_TOOLS)"
                fi
            done
        done <<<"$tools_val"
    done
}

# Test: Every agent has a Restrictions section
test_agent_restrictions_section() {
    local agent_dir
    for agent_dir in "$AGENTS_DIR"/*/; do
        local agent_name
        agent_name="$(/usr/bin/basename "$agent_dir")"
        local agent_file="$agent_dir/${agent_name}.md"
        [ -f "$agent_file" ] || continue

        assert_true "command grep -q '## Restrictions' '$agent_file'" \
            "Agent $agent_name: missing '## Restrictions' section"
    done
}

# Test: Every agent has skills field in frontmatter
test_agent_skills_field() {
    local agent_dir
    for agent_dir in "$AGENTS_DIR"/*/; do
        local agent_name
        agent_name="$(/usr/bin/basename "$agent_dir")"
        local agent_file="$agent_dir/${agent_name}.md"
        [ -f "$agent_file" ] || continue

        assert_true "command grep -q '^skills:' '$agent_file'" \
            "Agent $agent_name: missing 'skills' field in frontmatter"
    done
}

# Test: Every agent has a Tool Rationale section
test_agent_tool_rationale_section() {
    local agent_dir
    for agent_dir in "$AGENTS_DIR"/*/; do
        local agent_name
        agent_name="$(/usr/bin/basename "$agent_dir")"
        local agent_file="$agent_dir/${agent_name}.md"
        [ -f "$agent_file" ] || continue

        assert_true "command grep -q '## Tool Rationale' '$agent_file'" \
            "Agent $agent_name: missing '## Tool Rationale' section"
    done
}

# --- Skill Tests ---

# Test: Every skill directory has SKILL.md
test_skill_files_exist() {
    local skill_dir
    for skill_dir in "$SKILLS_DIR"/*/; do
        local skill_name
        skill_name="$(/usr/bin/basename "$skill_dir")"
        assert_file_exists "$skill_dir/SKILL.md" "Skill $skill_name missing SKILL.md"
    done
}

# Test: Every skill has a description in frontmatter
test_skill_frontmatter() {
    local skill_dir
    for skill_dir in "$SKILLS_DIR"/*/; do
        local skill_name
        skill_name="$(/usr/bin/basename "$skill_dir")"
        local skill_file="$skill_dir/SKILL.md"
        [ -f "$skill_file" ] || continue

        local desc_val
        desc_val="$(get_frontmatter_field "$skill_file" "description")"
        assert_not_empty "$desc_val" "Skill $skill_name: missing 'description' in SKILL.md frontmatter"
    done
}

# Test: Every skill directory has metadata.yml
test_skill_metadata_exists() {
    local skill_dir
    for skill_dir in "$SKILLS_DIR"/*/; do
        local skill_name
        skill_name="$(/usr/bin/basename "$skill_dir")"
        # container-environment is dynamically generated — skip metadata check
        [ "$skill_name" = "container-environment" ] && continue
        assert_file_exists "$skill_dir/metadata.yml" "Skill $skill_name missing metadata.yml"
    done
}

# Test: metadata.yml name matches directory name
test_skill_metadata_name_match() {
    local skill_dir
    for skill_dir in "$SKILLS_DIR"/*/; do
        local skill_name
        skill_name="$(/usr/bin/basename "$skill_dir")"
        local meta_file="$skill_dir/metadata.yml"
        [ -f "$meta_file" ] || continue

        local meta_name
        meta_name="$(command grep '^name:' "$meta_file" | command sed 's/^name:[[:space:]]*//')"
        [ -z "$meta_name" ] && continue
        assert_equals "$meta_name" "$skill_name" "Skill $skill_name: metadata.yml name mismatch"
    done
}

# Test: check-* skills have 5-file structure
test_check_skill_structure() {
    local required_files="SKILL.md patterns.sh contract.md thresholds.yml metadata.yml"
    local skill_dir
    for skill_dir in "$SKILLS_DIR"/check-*/; do
        [ -d "$skill_dir" ] || continue
        local skill_name
        skill_name="$(/usr/bin/basename "$skill_dir")"

        local file
        for file in $required_files; do
            assert_file_exists "$skill_dir/$file" \
                "check-* skill $skill_name missing required file: $file"
        done
    done
}

# Test: loop-* skills have 5-file structure
test_loop_skill_structure() {
    local required_files="SKILL.md patterns.sh contract.md thresholds.yml metadata.yml"
    local skill_dir
    for skill_dir in "$SKILLS_DIR"/loop-*/; do
        [ -d "$skill_dir" ] || continue
        local skill_name
        skill_name="$(/usr/bin/basename "$skill_dir")"

        local file
        for file in $required_files; do
            assert_file_exists "$skill_dir/$file" \
                "loop-* skill $skill_name missing required file: $file"
        done
    done
}

# Test: context-* skills have 3-file structure
test_context_skill_structure() {
    local required_files="SKILL.md context.yml metadata.yml"
    local skill_dir
    for skill_dir in "$SKILLS_DIR"/context-*/; do
        [ -d "$skill_dir" ] || continue
        local skill_name
        skill_name="$(/usr/bin/basename "$skill_dir")"

        local file
        for file in $required_files; do
            assert_file_exists "$skill_dir/$file" \
                "context-* skill $skill_name missing required file: $file"
        done
    done
}

# Test: patterns.sh files are executable
test_patterns_sh_executable() {
    local patterns_file
    while IFS= read -r patterns_file; do
        local skill_name
        skill_name="$(/usr/bin/basename "$(/usr/bin/dirname "$patterns_file")")"
        assert_true "[ -x '$patterns_file' ]" \
            "Skill $skill_name: patterns.sh is not executable"
    done < <(command find "$SKILLS_DIR" -name "patterns.sh" -type f 2>/dev/null | sort)
}

# --- Cross-Reference Tests ---

# Test: Every skill directory is listed in skills-and-agents.md
test_skills_in_docs() {
    [ -f "$DOCS_FILE" ] || return 0

    local skill_dir
    for skill_dir in "$SKILLS_DIR"/*/; do
        local skill_name
        skill_name="$(/usr/bin/basename "$skill_dir")"

        # Check if skill appears in the docs file (as backtick-wrapped name in table)
        assert_true "command grep -q '\`${skill_name}\`' '$DOCS_FILE'" \
            "Skill $skill_name not listed in skills-and-agents.md"
    done
}

# Test: Every agent directory is listed in skills-and-agents.md
test_agents_in_docs() {
    [ -f "$DOCS_FILE" ] || return 0

    local agent_dir
    for agent_dir in "$AGENTS_DIR"/*/; do
        local agent_name
        agent_name="$(/usr/bin/basename "$agent_dir")"

        assert_true "command grep -q '\`${agent_name}\`' '$DOCS_FILE'" \
            "Agent $agent_name not listed in skills-and-agents.md"
    done
}

# --- Workflow Harness Tests ---

# Test: Every workflow.js `export const meta` block is a pure literal.
# The Workflow tool rejects a meta object containing any non-literal node
# (variables, calls, spreads, template interpolation, or string concatenation)
# with "meta must be a pure literal". Multi-line `'...' + '...'` concatenation
# in meta.description is the common trap — a BinaryExpression, not a literal —
# and silently disables the harness at load time (see #561). This guard scans
# the meta block (from `export const meta` to its closing `}`) for any `+`
# concatenation or `${` interpolation.
test_workflow_meta_pure_literal() {
    local wf_file
    while IFS= read -r wf_file; do
        [ -f "$wf_file" ] || continue
        local rel_name
        rel_name="$(/usr/bin/basename "$(/usr/bin/dirname "$wf_file")")"

        # Extract the meta object by brace-counting: start at the line holding
        # `export const meta`, track { vs } depth, stop when depth returns to
        # zero. Robust against nested object literals in `phases` (a naive
        # "first }-at-column-0" match could stop early on a future layout). Held
        # in a variable — no temp file to leak on an assertion failure.
        local meta_block
        meta_block="$(/usr/bin/awk '
            /export const meta/ { capturing = 1 }
            capturing {
                print
                depth += gsub(/{/, "{")
                depth -= gsub(/}/, "}")
                if (started && depth <= 0) exit
                if (depth > 0) started = 1
            }
        ' "$wf_file")"

        # A pure-literal meta has no string concatenation (a `+` operator
        # adjacent to a quote — single OR double) and no template interpolation
        # (${...}). Each check is a self-contained boolean so one violation
        # never aborts the sweep over the remaining workflow.js files.
        if printf '%s\n' "$meta_block" |
            command grep -qE "['\"][[:space:]]*[+]|[+][[:space:]]*['\"]"; then
            assert_true false \
                "Workflow $rel_name: meta uses string concatenation (must be a single literal — see #561)"
        else
            assert_true true "Workflow $rel_name: meta has no string concatenation"
        fi

        if printf '%s\n' "$meta_block" | command grep -qF '${'; then
            assert_true false \
                "Workflow $rel_name: meta uses template interpolation (must be a pure literal)"
        else
            assert_true true "Workflow $rel_name: meta has no template interpolation"
        fi
    done < <(command find "$AGENTS_DIR" "$SKILLS_DIR" -name "workflow.js" -type f 2>/dev/null | /usr/bin/sort)
}

# --- Run All Tests ---

run_test test_agent_files_exist "Every agent has correctly named .md file"
run_test test_agent_frontmatter_fields "Every agent has required frontmatter fields"
run_test test_agent_model_values "Agent model values are valid (opus/sonnet/haiku)"
run_test test_agent_tool_values "Agent tool values are from valid set"
run_test test_agent_restrictions_section "Every agent has Restrictions section"
run_test test_agent_skills_field "Every agent has 'skills' field in frontmatter"
run_test test_agent_tool_rationale_section "Every agent has Tool Rationale section"
run_test test_skill_files_exist "Every skill has SKILL.md"
run_test test_skill_frontmatter "Every skill has description in frontmatter"
run_test test_skill_metadata_exists "Every skill has metadata.yml"
run_test test_skill_metadata_name_match "Skill metadata.yml name matches directory"
run_test test_check_skill_structure "check-* skills have 5-file structure"
run_test test_loop_skill_structure "loop-* skills have 5-file structure"
run_test test_context_skill_structure "context-* skills have 3-file structure"
run_test test_patterns_sh_executable "patterns.sh files are executable"
run_test test_skills_in_docs "Every skill listed in skills-and-agents.md"
run_test test_agents_in_docs "Every agent listed in skills-and-agents.md"
run_test test_workflow_meta_pure_literal "Every workflow.js meta is a pure literal (no concat/interpolation)"

# Generate test report
generate_report
