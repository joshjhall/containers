#!/usr/bin/env bash
# Structural lint for the repo's build-bound Claude Code skills
#
# The general-purpose skills/agents (and their workflow.js harnesses, patterns.sh
# pre-scans, and cross-file contract invariants) now ship as the joshjhall/librarian
# plugin marketplace — their structural lint lives there (issue #611, epic #607).
# What remains in this repo under lib/features/templates/claude/ are the three
# BUILD-BOUND skills that stay here: container-environment and cloud-infrastructure
# (generated dynamically at runtime) and docker-development (a static template).
#
# Validates the build-bound skills:
# - Every skill dir has SKILL.md with a description in frontmatter
# - Every skill dir has metadata.yml whose name matches the directory
# - Every skill is listed in docs/claude-code/skills-and-agents.md
#
# No Docker required — pure filesystem checks against the templates directory.

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
DOCS_FILE="$CONTAINERS_DIR/docs/claude-code/skills-and-agents.md"

# Define test suite
test_suite "Claude Build-Bound Skill Structural Lint"

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

# Test: Every skill directory has metadata.yml. All three build-bound skills
# ship a metadata.yml in the source tree (container-environment's SKILL.md is
# regenerated at runtime, but its metadata.yml is static), so the check is
# unconditional — a missing file is always a regression.
test_skill_metadata_exists() {
    local skill_dir
    for skill_dir in "$SKILLS_DIR"/*/; do
        local skill_name
        skill_name="$(/usr/bin/basename "$skill_dir")"
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

# --- Cross-Reference Tests ---

# Test: Every build-bound skill is listed in skills-and-agents.md
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

# Test: only the three expected build-bound skills remain in this repo. The
# general-purpose skills/agents migrated to librarian (#611); this guards against
# a regression that re-introduces a migrated artifact as a second source of truth.
test_only_build_bound_skills_remain() {
    local expected="cloud-infrastructure container-environment docker-development"
    local found
    found="$(command find "$SKILLS_DIR" -mindepth 1 -maxdepth 1 -type d \
        -exec /usr/bin/basename {} \; 2>/dev/null | /usr/bin/sort | /usr/bin/tr '\n' ' ' | command sed 's/[[:space:]]*$//')"
    assert_equals "$expected" "$found" \
        "Only the 3 build-bound skills should remain under templates/claude/skills (got: $found)"

    # No agents/ or hooks/ trees should linger — both migrated to librarian.
    assert_true "[ ! -d '$TEMPLATES_DIR/agents' ]" \
        "templates/claude/agents must be gone (agents migrated to librarian)"
    assert_true "[ ! -e '$TEMPLATES_DIR/hooks/golem-notify.sh' ]" \
        "golem-notify.sh must be gone (now in the librarian workflow plugin)"
}

# --- Run all tests ---
run_test test_skill_files_exist "Every build-bound skill has SKILL.md"
run_test test_skill_frontmatter "Every build-bound skill has description in frontmatter"
run_test test_skill_metadata_exists "Every build-bound skill has metadata.yml"
run_test test_skill_metadata_name_match "Skill metadata.yml name matches directory"
run_test test_skills_in_docs "Every build-bound skill listed in skills-and-agents.md"
run_test test_only_build_bound_skills_remain "Only the 3 build-bound skills remain (migrated artifacts removed)"

# Generate test report
generate_report
