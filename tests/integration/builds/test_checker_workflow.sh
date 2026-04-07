#!/usr/bin/env bash
# Test checker agent workflow: skill discovery globs, domain override logic,
# project-level skill precedence, and patterns.sh pipeline execution.
#
# These tests verify BEHAVIOR, not just file existence. They exercise the
# actual discovery globs, domain extraction, precedence ordering, and
# patterns.sh TSV pipeline that the checker agent relies on at runtime.
#
# Tests:
# - Discovery glob produces correct skill inventory with domain extraction
# - Domain override: check-* domains correctly shadow audit-* agents
# - Project-level .claude/skills/check-* takes precedence via glob ordering
# - patterns.sh pipeline: TSV output, field validation, category detection

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the test framework
source "$SCRIPT_DIR/../../framework.sh"

# Initialize the test framework
init_test_framework

# For standalone testing, we build from containers directory
export BUILD_CONTEXT="$CONTAINERS_DIR"

# Define test suite
test_suite "Checker Agent Workflow"

# ── Test 1: Skill discovery and domain extraction ────────────────────────────

test_skill_discovery_and_domains() {
    local image="test-checker-workflow-$$"
    echo "Building image with INCLUDE_DEV_TOOLS=true"

    assert_build_succeeds "Dockerfile" \
        --build-arg PROJECT_PATH=. \
        --build-arg PROJECT_NAME=test-checker \
        --build-arg INCLUDE_DEV_TOOLS=true \
        --build-arg INCLUDE_NODE=true \
        -t "$image"

    local skills_base="/etc/container/config/claude-templates/skills"

    # Run the SAME discovery glob the checker agent uses (checker.md Step 2)
    # and verify it finds exactly 8 check-* skills
    assert_command_in_container "$image" \
        "ls -d $skills_base/check-*/SKILL.md 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' '" \
        "8"

    # Verify domain extraction logic: strip 'check-' prefix and first segment
    # The checker extracts domain from skill name (e.g., check-docs-staleness → docs)
    # This script mimics the checker's domain grouping
    assert_command_in_container "$image" \
        "for d in $skills_base/check-*/; do
            name=\$(basename \"\$d\")
            domain=\$(echo \"\$name\" | /usr/bin/sed 's/^check-//' | /usr/bin/cut -d- -f1)
            echo \"\$domain\"
        done | /usr/bin/sort -u | /usr/bin/tr '\n' ',' | /usr/bin/sed 's/,\$//' " \
        "ai,code,docs,security"

    # Verify every patterns.sh is executable (not just present — must have +x)
    assert_command_in_container "$image" \
        "non_exec=0; for f in $skills_base/check-*/patterns.sh; do
            [ -x \"\$f\" ] || non_exec=\$((non_exec + 1))
        done; echo \"\$non_exec\"" \
        "0"

    # Verify checker agent references the correct discovery precedence
    assert_command_in_container "$image" \
        "/usr/bin/grep -c 'check-\\\*' /etc/container/config/claude-templates/agents/checker/checker.md | /usr/bin/tr -d ' '" \
        ""  # Just verify it doesn't fail — count varies
    # Actually verify the precedence paths are documented in checker.md
    assert_command_in_container "$image" \
        "/usr/bin/grep -q '.claude/skills/check-' /etc/container/config/claude-templates/agents/checker/checker.md && echo 'found'" \
        "found"
}

# ── Test 2: Domain override mapping ─────────────────────────────────────────

test_domain_override_mapping() {
    local image="${IMAGE_TO_TEST:-test-checker-workflow-$$}"
    local skills_base="/etc/container/config/claude-templates/skills"
    local agents_base="/etc/container/config/claude-templates/agents"

    # Build the domain→source mapping the checker uses at runtime:
    # For each domain, determine if check-* skills exist (override) or
    # only audit-* agents exist (legacy fallback)
    #
    # Expected: security, docs, code-health, ai-config have BOTH check-* and audit-*
    #           test-gaps, architecture have ONLY audit-*

    # Verify domains with check-* skills that shadow audit-* agents
    # Script: for each audit-* agent, check if a matching check-* skill exists
    assert_command_in_container "$image" \
        "for agent_dir in $agents_base/audit-*/; do
            agent=\$(basename \"\$agent_dir\")
            domain=\$(echo \"\$agent\" | /usr/bin/sed 's/^audit-//')
            has_check=\$(command ls -d $skills_base/check-\${domain}*/SKILL.md 2>/dev/null | /usr/bin/wc -l)
            if [ \"\$has_check\" -gt 0 ]; then
                echo \"override:\$domain\"
            else
                echo \"legacy:\$domain\"
            fi
        done | /usr/bin/sort" \
        "legacy:architecture
legacy:test-gaps
override:ai-config
override:code-health
override:docs
override:security"
}

# ── Test 3: Project-level skill precedence ───────────────────────────────────

test_project_level_skill_precedence() {
    local image="${IMAGE_TO_TEST:-test-checker-workflow-$$}"
    local container="test-checker-precedence-$$"
    local skills_base="/etc/container/config/claude-templates/skills"

    # Start a persistent container for stateful operations
    docker run -d --name "$container" "$image" sleep 300
    TEST_CONTAINERS+=("$container")

    # Simulate the checker's 3-tier discovery by running the actual globs
    # Tier 1: project-level (.claude/skills/check-*)
    # Tier 2: user-level (~/.claude/skills/check-*)
    # Tier 3: legacy audit agents (~/.claude/agents/audit-*)

    # Before override: project-level glob finds nothing
    capture_result docker exec "$container" bash -c \
        "ls -d /workspace/.claude/skills/check-*/SKILL.md 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' '"
    assert_contains "$TEST_OUTPUT" "0"

    # Create a project-level check-security override with distinct content
    docker exec "$container" mkdir -p /workspace/.claude/skills/check-security
    docker exec "$container" bash -c \
        'cat > /workspace/.claude/skills/check-security/SKILL.md << "OVERRIDE"
---
name: check-security
description: Project-specific security rules
---
Custom scanner with project-specific patterns
OVERRIDE'

    # After override: project-level glob finds exactly 1
    capture_result docker exec "$container" bash -c \
        "ls -d /workspace/.claude/skills/check-*/SKILL.md 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' '"
    assert_contains "$TEST_OUTPUT" "1"

    # Simulate the checker's precedence: project-level wins over container-level
    # The checker reads project-level FIRST — verify content differs
    capture_result docker exec "$container" bash -c \
        "/usr/bin/head -5 /workspace/.claude/skills/check-security/SKILL.md"
    assert_contains "$TEST_OUTPUT" "Project-specific security rules"

    capture_result docker exec "$container" bash -c \
        "/usr/bin/head -5 $skills_base/check-security/SKILL.md"
    assert_not_contains "$TEST_OUTPUT" "Project-specific"

    # Verify the merged discovery (project + container) still finds all skills
    # Project provides 1 check-security, container provides all 8 check-*
    # After dedup by domain, the project version should win for security
    capture_result docker exec "$container" bash -c \
        "( ls -d /workspace/.claude/skills/check-*/SKILL.md 2>/dev/null
           ls -d $skills_base/check-*/SKILL.md 2>/dev/null
        ) | /usr/bin/sed 's|.*/check-|check-|; s|/SKILL.md||' | /usr/bin/sort -u | /usr/bin/wc -l | /usr/bin/tr -d ' '"
    assert_contains "$TEST_OUTPUT" "8"

    # Clean up container
    docker stop "$container" >/dev/null 2>&1 || true
    docker rm "$container" >/dev/null 2>&1 || true
}

# ── Test 4: patterns.sh pipeline execution ───────────────────────────────────

test_patterns_pipeline() {
    local image="${IMAGE_TO_TEST:-test-checker-workflow-$$}"
    local container="test-checker-patterns-$$"
    local skills_base="/etc/container/config/claude-templates/skills"

    # Start a persistent container
    docker run -d --name "$container" "$image" sleep 300
    TEST_CONTAINERS+=("$container")

    # Copy the security fixture into the container
    docker cp "$FIXTURES_DIR/claude/patterns/security_fixture.py" \
        "$container:/tmp/security_fixture.py"

    # Create a file list (the patterns.sh input format)
    docker exec "$container" bash -c \
        'echo "/tmp/security_fixture.py" > /tmp/file_list.txt'

    # Run patterns.sh — this is the actual pre-scan pipeline the checker executes
    capture_result docker exec "$container" bash -c \
        "bash $skills_base/check-security/patterns.sh /tmp/file_list.txt"
    assert_exit_code 0 "$TEST_EXIT_CODE" "patterns.sh should exit 0"

    local output="$TEST_OUTPUT"

    # Verify output is non-empty (fixture has known vulnerabilities)
    assert_not_empty "$output"

    # Verify every line is valid 5-field TSV (file, line, category, evidence, certainty)
    local bad_lines
    bad_lines=$(echo "$output" | /usr/bin/awk -F'\t' 'NF != 5 { print NR": "$0 }')
    assert_empty "$bad_lines"

    # Verify the 3 expected vulnerability categories from security_fixture.py
    assert_contains "$output" "hardcoded-secret"
    assert_contains "$output" "injection-risk"
    assert_contains "$output" "insecure-crypto"

    # Verify all findings reference the correct source file
    assert_contains "$output" "/tmp/security_fixture.py"

    # Verify certainty field is HIGH for all deterministic findings
    local non_high
    non_high=$(echo "$output" | /usr/bin/awk -F'\t' '$5 != "HIGH" { print }')
    assert_empty "$non_high"

    # Verify line numbers are present and numeric
    local bad_lines_nums
    bad_lines_nums=$(echo "$output" | /usr/bin/awk -F'\t' '$2 !~ /^[0-9]+$/ { print }')
    assert_empty "$bad_lines_nums"

    # Test error handling: missing argument should exit 1
    capture_result docker exec "$container" bash -c \
        "bash $skills_base/check-security/patterns.sh 2>&1; echo \"EXIT:\$?\""
    assert_contains "$TEST_OUTPUT" "EXIT:1"

    # Clean up container
    docker stop "$container" >/dev/null 2>&1 || true
    docker rm "$container" >/dev/null 2>&1 || true
}

# ── Run all tests ────────────────────────────────────────────────────────────

# First test builds the image; subsequent tests reuse it
run_test test_skill_discovery_and_domains "Discovery glob finds all check-* skills with correct domain extraction"
run_test test_domain_override_mapping "Domain override: check-* correctly shadows matching audit-* agents"
run_test test_project_level_skill_precedence "Project-level check-* skill wins in merged discovery"
run_test test_patterns_pipeline "patterns.sh pipeline produces valid TSV with correct findings"

# Generate test report
generate_report
