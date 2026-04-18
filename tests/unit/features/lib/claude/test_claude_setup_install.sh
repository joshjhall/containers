#!/usr/bin/env bash
# Unit tests for claude-setup skill/agent template installation
#
# Tests the cp logic in the skills & agents installation section of claude-setup.
# Specifically guards against the regression where `cp` without `-r` fails on
# skills/agents that contain subdirectories (e.g. next-issue/schemas/).
#
# Under set -euo pipefail, a bare `cp` failure aborts the entire script,
# preventing all subsequent installations (agents never reached).

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "claude-setup Template Installation Tests"

CLAUDE_SETUP="$PROJECT_ROOT/lib/features/lib/claude/claude-setup"

# Setup: create a fake templates dir and HOME, then extract the installation
# section into a standalone script we can run without needing claude CLI.
setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$RESULTS_DIR/test-claude-setup-install-$unique_id"

    # Fake HOME so we don't touch the real ~/.claude
    export FAKE_HOME="$TEST_TEMP_DIR/home"
    mkdir -p "$FAKE_HOME/.claude"

    # Fake templates dir (mimics /etc/container/config/claude-templates)
    export FAKE_TEMPLATES="$TEST_TEMP_DIR/templates"
    mkdir -p "$FAKE_TEMPLATES/skills" "$FAKE_TEMPLATES/agents"

    # Fake enabled-features file (empty — no cloud flags)
    export FAKE_FEATURES="$TEST_TEMP_DIR/enabled-features.conf"
    touch "$FAKE_FEATURES"
}

teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
    unset TEST_TEMP_DIR FAKE_HOME FAKE_TEMPLATES FAKE_FEATURES 2>/dev/null || true
}

# Helper: create a minimal skill template (flat — no subdirs)
_create_skill() {
    local name="$1"
    mkdir -p "$FAKE_TEMPLATES/skills/$name"
    command cat >"$FAKE_TEMPLATES/skills/$name/SKILL.md" <<EOF
---
description: "Test skill $name"
---
# $name
EOF
}

# Helper: create a skill with a subdirectory (the scenario that broke cp)
_create_skill_with_subdir() {
    local name="$1"
    local subdir="${2:-schemas}"
    mkdir -p "$FAKE_TEMPLATES/skills/$name/$subdir"
    command cat >"$FAKE_TEMPLATES/skills/$name/SKILL.md" <<EOF
---
description: "Test skill $name"
---
# $name
EOF
    echo '{}' >"$FAKE_TEMPLATES/skills/$name/$subdir/example.json"
}

# Helper: create a minimal agent template
_create_agent() {
    local name="$1"
    mkdir -p "$FAKE_TEMPLATES/agents/$name"
    command cat >"$FAKE_TEMPLATES/agents/$name/$name.md" <<EOF
---
name: $name
description: "Test agent $name"
---
# $name
EOF
}

# Helper: build a standalone installer script from claude-setup's install section.
# This extracts the relevant logic without needing the claude CLI, auth checks,
# plugin installation, or MCP configuration.
_build_installer() {
    command cat >"$TEST_TEMP_DIR/installer.sh" <<'INSTALLER'
#!/bin/bash
set -euo pipefail

TEMPLATES_DIR="$1"
CLAUDE_DIR="$2"
ENABLED_FEATURES_FILE="${3:-/dev/null}"

# Source enabled-features if it exists
if [ -f "$ENABLED_FEATURES_FILE" ]; then
    source "$ENABLED_FEATURES_FILE"
fi

# Stub the override helpers (use defaults for everything)
_is_in_list() { return 1; }

SKILL_LIST_IS_OVERRIDE=1
AGENT_LIST_IS_OVERRIDE=1

# --- Skills ---
if [ -d "$TEMPLATES_DIR/skills" ]; then
    for skill_dir in "$TEMPLATES_DIR/skills"/*/; do
        [ -d "$skill_dir" ] || continue
        skill_name=$(basename "$skill_dir")

        # Skip conditional skills
        [ "$skill_name" = "container-environment" ] && continue
        [ "$skill_name" = "docker-development" ] && continue
        [ "$skill_name" = "cloud-infrastructure" ] && continue

        target_dir="$CLAUDE_DIR/skills/$skill_name"
        if [ -d "$target_dir" ]; then
            echo "SKIP $skill_name"
        else
            mkdir -p "$target_dir"
            cp -r "$skill_dir"/* "$target_dir/"
            echo "INSTALLED skill:$skill_name"
        fi
    done
fi

# --- Agents ---
if [ -d "$TEMPLATES_DIR/agents" ]; then
    for agent_dir in "$TEMPLATES_DIR/agents"/*/; do
        [ -d "$agent_dir" ] || continue
        agent_name=$(basename "$agent_dir")

        target_dir="$CLAUDE_DIR/agents/$agent_name"
        if [ -d "$target_dir" ]; then
            echo "SKIP $agent_name"
        else
            mkdir -p "$target_dir"
            cp -r "$agent_dir"/* "$target_dir/"
            echo "INSTALLED agent:$agent_name"
        fi
    done
fi
INSTALLER
    chmod +x "$TEST_TEMP_DIR/installer.sh"
}

# ============================================================================
# Static Analysis: verify claude-setup uses cp -r
# ============================================================================

test_cp_uses_recursive_flag() {
    # Every cp that copies from a template dir variable into a target dir must use -r.
    # Match: cp "$skill_dir"/* or cp "$agent_dir"/* or cp "$TEMPLATES_DIR/skills/...
    local bare_cp_lines
    bare_cp_lines=$(command grep -nE 'cp "\$(skill_dir|agent_dir|TEMPLATES_DIR)' "$CLAUDE_SETUP" | command grep -v 'cp -r' || true)

    assert_empty "$bare_cp_lines" \
        "All cp commands for template dirs should use -r flag"
}

test_skill_cp_is_recursive() {
    # Specifically check the main skill installation line
    assert_file_contains "$CLAUDE_SETUP" 'cp -r "$skill_dir"' \
        "Skill installation uses cp -r"
}

test_agent_cp_is_recursive() {
    # Specifically check the main agent installation line
    assert_file_contains "$CLAUDE_SETUP" 'cp -r "$agent_dir"' \
        "Agent installation uses cp -r"
}

# ============================================================================
# Functional: flat skills and agents install correctly
# ============================================================================

test_flat_skills_install() {
    _create_skill "alpha"
    _create_skill "beta"
    _build_installer

    local output
    output=$(bash "$TEST_TEMP_DIR/installer.sh" "$FAKE_TEMPLATES" "$FAKE_HOME/.claude" "$FAKE_FEATURES")

    assert_contains "$output" "INSTALLED skill:alpha" "alpha skill installed"
    assert_contains "$output" "INSTALLED skill:beta" "beta skill installed"
    assert_file_exists "$FAKE_HOME/.claude/skills/alpha/SKILL.md"
    assert_file_exists "$FAKE_HOME/.claude/skills/beta/SKILL.md"
}

test_agents_install() {
    _create_agent "code-reviewer"
    _create_agent "debugger"
    _build_installer

    local output
    output=$(bash "$TEST_TEMP_DIR/installer.sh" "$FAKE_TEMPLATES" "$FAKE_HOME/.claude" "$FAKE_FEATURES")

    assert_contains "$output" "INSTALLED agent:code-reviewer" "code-reviewer installed"
    assert_contains "$output" "INSTALLED agent:debugger" "debugger installed"
    assert_file_exists "$FAKE_HOME/.claude/agents/code-reviewer/code-reviewer.md"
    assert_file_exists "$FAKE_HOME/.claude/agents/debugger/debugger.md"
}

# ============================================================================
# Functional: skills with subdirectories (regression test for cp -r bug)
# ============================================================================

test_skill_with_subdir_installs() {
    # This is the exact scenario that broke: next-issue has a schemas/ subdir.
    # Without cp -r, this fails and (under set -e) kills the script.
    _create_skill_with_subdir "next-issue" "schemas"
    _build_installer

    local output exit_code=0
    output=$(bash "$TEST_TEMP_DIR/installer.sh" "$FAKE_TEMPLATES" "$FAKE_HOME/.claude" "$FAKE_FEATURES") || exit_code=$?

    assert_equals "0" "$exit_code" \
        "Installer should not fail on skills with subdirectories"
    assert_contains "$output" "INSTALLED skill:next-issue" \
        "next-issue skill should be installed"
    assert_file_exists "$FAKE_HOME/.claude/skills/next-issue/SKILL.md" \
        "SKILL.md should be copied"
    assert_dir_exists "$FAKE_HOME/.claude/skills/next-issue/schemas" \
        "schemas/ subdirectory should be copied recursively"
    assert_file_exists "$FAKE_HOME/.claude/skills/next-issue/schemas/example.json" \
        "Files inside subdirectory should be copied"
}

test_subdir_skill_does_not_block_agents() {
    # The original bug: a skill subdir caused cp to fail, aborting before agents
    _create_skill_with_subdir "next-issue" "schemas"
    _create_skill "orchestrate"
    _create_agent "code-reviewer"
    _create_agent "test-writer"
    _build_installer

    local output exit_code=0
    output=$(bash "$TEST_TEMP_DIR/installer.sh" "$FAKE_TEMPLATES" "$FAKE_HOME/.claude" "$FAKE_FEATURES") || exit_code=$?

    assert_equals "0" "$exit_code" \
        "Installer should complete successfully"

    # Skills after the subdir skill should still install
    assert_contains "$output" "INSTALLED skill:orchestrate" \
        "Skills after subdir skill should install"

    # Agents should install (this was the main failure before the fix)
    assert_contains "$output" "INSTALLED agent:code-reviewer" \
        "Agents should install even when skills have subdirectories"
    assert_contains "$output" "INSTALLED agent:test-writer" \
        "All agents should install"
}

# ============================================================================
# Functional: idempotent (already-installed items are skipped)
# ============================================================================

test_already_installed_skills_skipped() {
    _create_skill "alpha"
    _build_installer

    # First run
    bash "$TEST_TEMP_DIR/installer.sh" "$FAKE_TEMPLATES" "$FAKE_HOME/.claude" "$FAKE_FEATURES" >/dev/null

    # Second run
    local output
    output=$(bash "$TEST_TEMP_DIR/installer.sh" "$FAKE_TEMPLATES" "$FAKE_HOME/.claude" "$FAKE_FEATURES")

    assert_contains "$output" "SKIP alpha" \
        "Already-installed skill should be skipped"
    assert_not_contains "$output" "INSTALLED skill:alpha" \
        "Should not re-install existing skill"
}

test_already_installed_agents_skipped() {
    _create_agent "debugger"
    _build_installer

    # First run
    bash "$TEST_TEMP_DIR/installer.sh" "$FAKE_TEMPLATES" "$FAKE_HOME/.claude" "$FAKE_FEATURES" >/dev/null

    # Second run
    local output
    output=$(bash "$TEST_TEMP_DIR/installer.sh" "$FAKE_TEMPLATES" "$FAKE_HOME/.claude" "$FAKE_FEATURES")

    assert_contains "$output" "SKIP debugger" \
        "Already-installed agent should be skipped"
    assert_not_contains "$output" "INSTALLED agent:debugger" \
        "Should not re-install existing agent"
}

# ============================================================================
# Functional: conditional skills are skipped
# ============================================================================

test_conditional_skills_skipped() {
    _create_skill "container-environment"
    _create_skill "docker-development"
    _create_skill "cloud-infrastructure"
    _create_skill "regular-skill"
    _build_installer

    local output
    output=$(bash "$TEST_TEMP_DIR/installer.sh" "$FAKE_TEMPLATES" "$FAKE_HOME/.claude" "$FAKE_FEATURES")

    assert_not_contains "$output" "container-environment" \
        "container-environment should be skipped (dynamic)"
    assert_not_contains "$output" "docker-development" \
        "docker-development should be skipped (conditional)"
    assert_not_contains "$output" "cloud-infrastructure" \
        "cloud-infrastructure should be skipped (conditional)"
    assert_contains "$output" "INSTALLED skill:regular-skill" \
        "Regular skills should still install"
}

# ============================================================================
# Run all tests
# ============================================================================

# Static analysis
run_test test_cp_uses_recursive_flag "claude-setup: all template cp commands use -r"
run_test test_skill_cp_is_recursive "claude-setup: skill cp uses -r flag"
run_test test_agent_cp_is_recursive "claude-setup: agent cp uses -r flag"

# Functional — basic installation
run_test test_flat_skills_install "install: flat skills copy correctly"
run_test test_agents_install "install: agents copy correctly"

# Functional — subdirectory regression
run_test test_skill_with_subdir_installs "install: skill with subdirectory copies recursively"
run_test test_subdir_skill_does_not_block_agents "install: subdir skill does not block agent installation"

# Functional — idempotency
run_test test_already_installed_skills_skipped "install: already-installed skills are skipped"
run_test test_already_installed_agents_skipped "install: already-installed agents are skipped"

# Functional — conditional skills
run_test test_conditional_skills_skipped "install: conditional skills are skipped in main loop"

# Generate test report
generate_report
