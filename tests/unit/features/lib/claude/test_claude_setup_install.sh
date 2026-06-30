#!/usr/bin/env bash
# Unit tests for claude-setup skill/agent/hook installation
#
# The general-purpose skills/agents now ship as the librarian plugins (installed
# from the local /opt/librarian marketplace). What claude-setup still installs
# from the staged templates are the BUILD-BOUND skills (docker-development) plus
# user-additive CLAUDE_EXTRA_SKILLS / CLAUDE_EXTRA_AGENTS, and the golem hook.
#
# These tests guard:
#   - the cp -r regression: a bare `cp` fails on a skill/agent with subdirs and
#     (under set -euo pipefail) aborts the whole script, so every template cp
#     must use -r.
#   - absent-only install semantics for the build-bound + extra artifacts
#     (install once, skip thereafter; --refresh forces a build-bound rewrite).
#   - the librarian local-marketplace install block exists and is offline.

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
    mkdir -p "$FAKE_TEMPLATES/skills" "$FAKE_TEMPLATES/agents" "$FAKE_TEMPLATES/hooks"
}

teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
    unset TEST_TEMP_DIR FAKE_HOME FAKE_TEMPLATES 2>/dev/null || true
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

# Helper: create a minimal hook script (flat file). The template staging step
# strips +x (chmod -R 644), so create it non-executable to mirror reality.
_create_hook() {
    local name="$1"
    command cat >"$FAKE_TEMPLATES/hooks/$name" <<EOF
#!/usr/bin/env bash
echo "hook $name"
EOF
    chmod 644 "$FAKE_TEMPLATES/hooks/$name"
}

# Helper: build a standalone installer script mirroring the parts of claude-setup
# that copy from the staged templates: the CLAUDE_EXTRA_SKILLS / CLAUDE_EXTRA_AGENTS
# additive loops (absent-only), the build-bound docker-development copy, and the
# hooks loop. This extracts the cp logic without needing the claude CLI, auth, or
# the librarian / official plugin install.
_build_installer() {
    command cat >"$TEST_TEMP_DIR/installer.sh" <<'INSTALLER'
#!/bin/bash
set -euo pipefail

TEMPLATES_DIR="$1"
CLAUDE_DIR="$2"
# Mirror claude-setup's --refresh flag: pass "--refresh" as $3 to force a
# build-bound rewrite.
REFRESH_MODE=false
[ "${3:-}" = "--refresh" ] && REFRESH_MODE=true

# Treat every skill/agent passed in env as an additive extra (mirrors the
# CLAUDE_EXTRA_* loops). Defaults exercise the docker-development build-bound copy.
EXTRA_SKILLS="${EXTRA_SKILLS:-}"
EXTRA_AGENTS="${EXTRA_AGENTS:-}"

# _buildbound_needs_install — verbatim copy of the production gate (claude-setup):
# (re)write when the target is absent or --refresh was passed; else keep the copy.
_buildbound_needs_install() {
    local target_dir="$1"
    [ ! -d "$target_dir" ] && return 0
    [ "$REFRESH_MODE" = "true" ] && return 0
    return 1
}

# --- Extra Skills (additive, absent-only) ---
if [ -n "$EXTRA_SKILLS" ]; then
    IFS=',' read -ra EXTRA_SKILL_LIST <<< "$EXTRA_SKILLS"
    for skill_name in "${EXTRA_SKILL_LIST[@]}"; do
        skill_name=$(echo "$skill_name" | xargs)
        [ -z "$skill_name" ] && continue
        skill_dir="$TEMPLATES_DIR/skills/$skill_name"
        target_dir="$CLAUDE_DIR/skills/$skill_name"
        if [ -d "$target_dir" ]; then
            echo "SKIP skill:$skill_name"
        elif [ -d "$skill_dir" ]; then
            mkdir -p "$target_dir"
            cp -r "$skill_dir"/* "$target_dir/"
            echo "INSTALLED skill:$skill_name"
        else
            echo "MISSING skill:$skill_name"
        fi
    done
fi

# --- Build-bound: docker-development (absent-only copy from template) ---
if [ -d "$TEMPLATES_DIR/skills/docker-development" ]; then
    target_dir="$CLAUDE_DIR/skills/docker-development"
    if ! _buildbound_needs_install "$target_dir"; then
        echo "SKIP skill:docker-development"
    else
        mkdir -p "$target_dir"
        cp -r "$TEMPLATES_DIR/skills/docker-development/"* "$target_dir/"
        echo "INSTALLED skill:docker-development"
    fi
fi

# --- Extra Agents (additive, absent-only) ---
if [ -n "$EXTRA_AGENTS" ]; then
    IFS=',' read -ra EXTRA_AGENT_LIST <<< "$EXTRA_AGENTS"
    for agent_name in "${EXTRA_AGENT_LIST[@]}"; do
        agent_name=$(echo "$agent_name" | xargs)
        [ -z "$agent_name" ] && continue
        agent_dir="$TEMPLATES_DIR/agents/$agent_name"
        target_dir="$CLAUDE_DIR/agents/$agent_name"
        if [ -d "$target_dir" ]; then
            echo "SKIP agent:$agent_name"
        elif [ -d "$agent_dir" ]; then
            mkdir -p "$target_dir"
            cp -r "$agent_dir"/* "$target_dir/"
            echo "INSTALLED agent:$agent_name"
        else
            echo "MISSING agent:$agent_name"
        fi
    done
fi

# --- Hooks ---
if [ -d "$TEMPLATES_DIR/hooks" ]; then
    mkdir -p "$CLAUDE_DIR/hooks"
    for hook_file in "$TEMPLATES_DIR/hooks"/*; do
        [ -f "$hook_file" ] || continue
        hook_name=$(basename "$hook_file")
        target_file="$CLAUDE_DIR/hooks/$hook_name"
        if [ -f "$target_file" ]; then
            echo "SKIP $hook_name"
        else
            cp "$hook_file" "$target_file"
            chmod 755 "$target_file"
            echo "INSTALLED hook:$hook_name"
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
    # The CLAUDE_EXTRA_SKILLS additive loop copies a skill dir.
    assert_file_contains "$CLAUDE_SETUP" 'cp -r "$skill_dir"' \
        "Skill installation uses cp -r"
}

test_agent_cp_is_recursive() {
    # The CLAUDE_EXTRA_AGENTS additive loop copies an agent dir.
    assert_file_contains "$CLAUDE_SETUP" 'cp -r "$agent_dir"' \
        "Agent installation uses cp -r"
}

test_production_has_buildbound_gate() {
    # The functional tests inline a copy of _buildbound_needs_install. Guard
    # against drift: production must define the function and gate a build-bound
    # install on it. If these break, the inline test copy may silently diverge.
    assert_file_contains "$CLAUDE_SETUP" '_buildbound_needs_install()' \
        "claude-setup defines _buildbound_needs_install"
    assert_file_contains "$CLAUDE_SETUP" 'if ! _buildbound_needs_install "$target_dir"' \
        "claude-setup gates a build-bound install on _buildbound_needs_install"
    assert_file_contains "$CLAUDE_SETUP" 'REFRESH_MODE' \
        "claude-setup honors a --refresh / REFRESH_MODE branch"
}

test_no_stamp_machinery() {
    # The #574 content-stamp re-sync was removed in favor of the librarian
    # version pin. None of its machinery should remain.
    local hits
    hits=$(command grep -nE '_bundled_needs_sync|STAGED_STAMP|INSTALLED_STAMP|\.template-stamp' "$CLAUDE_SETUP" || true)
    assert_empty "$hits" \
        "claude-setup should no longer reference the #574 stamp machinery"
}

test_librarian_offline_install_present() {
    # The librarian plugins install from the local /opt/librarian marketplace,
    # offline and without auth — outside the auth-gated official plugin block.
    assert_file_contains "$CLAUDE_SETUP" '/opt/librarian' \
        "claude-setup installs from the local /opt/librarian marketplace"
    assert_file_contains "$CLAUDE_SETUP" 'claude plugin marketplace add "$LIBRARIAN_DIR"' \
        "claude-setup registers the local librarian marketplace"
    assert_file_contains "$CLAUDE_SETUP" 'CLAUDE_LIBRARIAN_PLUGINS' \
        "claude-setup honors the CLAUDE_LIBRARIAN_PLUGINS override"
}

# ============================================================================
# Functional: extra skills and agents install correctly (cp -r path)
# ============================================================================

test_flat_skills_install() {
    _create_skill "alpha"
    _create_skill "beta"
    _build_installer

    local output
    output=$(EXTRA_SKILLS="alpha,beta" bash "$TEST_TEMP_DIR/installer.sh" "$FAKE_TEMPLATES" "$FAKE_HOME/.claude")

    assert_contains "$output" "INSTALLED skill:alpha" "alpha skill installed"
    assert_contains "$output" "INSTALLED skill:beta" "beta skill installed"
    assert_file_exists "$FAKE_HOME/.claude/skills/alpha/SKILL.md"
    assert_file_exists "$FAKE_HOME/.claude/skills/beta/SKILL.md"
}

test_agents_install() {
    _create_agent "my-reviewer"
    _create_agent "my-debugger"
    _build_installer

    local output
    output=$(EXTRA_AGENTS="my-reviewer,my-debugger" bash "$TEST_TEMP_DIR/installer.sh" "$FAKE_TEMPLATES" "$FAKE_HOME/.claude")

    assert_contains "$output" "INSTALLED agent:my-reviewer" "my-reviewer installed"
    assert_contains "$output" "INSTALLED agent:my-debugger" "my-debugger installed"
    assert_file_exists "$FAKE_HOME/.claude/agents/my-reviewer/my-reviewer.md"
    assert_file_exists "$FAKE_HOME/.claude/agents/my-debugger/my-debugger.md"
}

# ============================================================================
# Functional: skills with subdirectories (regression test for cp -r bug)
# ============================================================================

test_skill_with_subdir_installs() {
    # The exact scenario that broke: a skill with a schemas/ subdir.
    # Without cp -r, this fails and (under set -e) kills the script.
    _create_skill_with_subdir "my-flow" "schemas"
    _build_installer

    local output exit_code=0
    output=$(EXTRA_SKILLS="my-flow" bash "$TEST_TEMP_DIR/installer.sh" "$FAKE_TEMPLATES" "$FAKE_HOME/.claude") || exit_code=$?

    assert_equals "0" "$exit_code" \
        "Installer should not fail on skills with subdirectories"
    assert_contains "$output" "INSTALLED skill:my-flow" \
        "my-flow skill should be installed"
    assert_file_exists "$FAKE_HOME/.claude/skills/my-flow/SKILL.md" \
        "SKILL.md should be copied"
    assert_dir_exists "$FAKE_HOME/.claude/skills/my-flow/schemas" \
        "schemas/ subdirectory should be copied recursively"
    assert_file_exists "$FAKE_HOME/.claude/skills/my-flow/schemas/example.json" \
        "Files inside subdirectory should be copied"
}

test_subdir_skill_does_not_block_agents() {
    # The original bug: a skill subdir caused cp to fail, aborting before agents
    _create_skill_with_subdir "my-flow" "schemas"
    _create_skill "plain"
    _create_agent "my-reviewer"
    _create_agent "my-writer"
    _build_installer

    local output exit_code=0
    output=$(EXTRA_SKILLS="my-flow,plain" EXTRA_AGENTS="my-reviewer,my-writer" \
        bash "$TEST_TEMP_DIR/installer.sh" "$FAKE_TEMPLATES" "$FAKE_HOME/.claude") || exit_code=$?

    assert_equals "0" "$exit_code" \
        "Installer should complete successfully"
    assert_contains "$output" "INSTALLED skill:plain" \
        "Skills after subdir skill should install"
    assert_contains "$output" "INSTALLED agent:my-reviewer" \
        "Agents should install even when skills have subdirectories"
    assert_contains "$output" "INSTALLED agent:my-writer" \
        "All agents should install"
}

# ============================================================================
# Functional: idempotent (already-installed items are skipped, absent-only)
# ============================================================================

test_already_installed_skills_skipped() {
    _create_skill "alpha"
    _build_installer

    EXTRA_SKILLS="alpha" bash "$TEST_TEMP_DIR/installer.sh" "$FAKE_TEMPLATES" "$FAKE_HOME/.claude" >/dev/null

    local output
    output=$(EXTRA_SKILLS="alpha" bash "$TEST_TEMP_DIR/installer.sh" "$FAKE_TEMPLATES" "$FAKE_HOME/.claude")

    assert_contains "$output" "SKIP skill:alpha" \
        "Already-installed skill should be skipped"
    assert_not_contains "$output" "INSTALLED skill:alpha" \
        "Should not re-install existing skill"
}

test_already_installed_agents_skipped() {
    _create_agent "my-debugger"
    _build_installer

    EXTRA_AGENTS="my-debugger" bash "$TEST_TEMP_DIR/installer.sh" "$FAKE_TEMPLATES" "$FAKE_HOME/.claude" >/dev/null

    local output
    output=$(EXTRA_AGENTS="my-debugger" bash "$TEST_TEMP_DIR/installer.sh" "$FAKE_TEMPLATES" "$FAKE_HOME/.claude")

    assert_contains "$output" "SKIP agent:my-debugger" \
        "Already-installed agent should be skipped"
    assert_not_contains "$output" "INSTALLED agent:my-debugger" \
        "Should not re-install existing agent"
}

# ============================================================================
# Functional: build-bound docker-development (absent-only, --refresh rewrites)
# ============================================================================

test_buildbound_docker_installs_then_skips() {
    _create_skill "docker-development"
    _build_installer

    local first
    first=$(bash "$TEST_TEMP_DIR/installer.sh" "$FAKE_TEMPLATES" "$FAKE_HOME/.claude")
    assert_contains "$first" "INSTALLED skill:docker-development" "docker-development installs first run"
    assert_file_exists "$FAKE_HOME/.claude/skills/docker-development/SKILL.md"

    local second
    second=$(bash "$TEST_TEMP_DIR/installer.sh" "$FAKE_TEMPLATES" "$FAKE_HOME/.claude")
    assert_contains "$second" "SKIP skill:docker-development" "second run skips (absent-only)"
}

test_buildbound_refresh_rewrites() {
    _create_skill "docker-development"
    _build_installer
    bash "$TEST_TEMP_DIR/installer.sh" "$FAKE_TEMPLATES" "$FAKE_HOME/.claude" >/dev/null

    local out
    out=$(bash "$TEST_TEMP_DIR/installer.sh" "$FAKE_TEMPLATES" "$FAKE_HOME/.claude" --refresh)
    assert_contains "$out" "INSTALLED skill:docker-development" \
        "--refresh rewrites the build-bound skill despite it already existing"
}

# ============================================================================
# Functional: hooks install (executable bit restored, idempotent)
# ============================================================================

test_hooks_install_executable() {
    # The template staging strips +x; the install loop must restore it so the
    # Claude Code runtime can exec the hook.
    _create_hook "golem-notify.sh"
    _build_installer

    local output
    output=$(bash "$TEST_TEMP_DIR/installer.sh" "$FAKE_TEMPLATES" "$FAKE_HOME/.claude")

    assert_contains "$output" "INSTALLED hook:golem-notify.sh" "hook installed"
    assert_file_exists "$FAKE_HOME/.claude/hooks/golem-notify.sh" "hook file copied"
    assert_true "[ -x '$FAKE_HOME/.claude/hooks/golem-notify.sh' ]" \
        "installed hook should be executable (+x restored)"
}

test_already_installed_hooks_skipped() {
    _create_hook "golem-notify.sh"
    _build_installer

    bash "$TEST_TEMP_DIR/installer.sh" "$FAKE_TEMPLATES" "$FAKE_HOME/.claude" >/dev/null

    local output
    output=$(bash "$TEST_TEMP_DIR/installer.sh" "$FAKE_TEMPLATES" "$FAKE_HOME/.claude")

    assert_contains "$output" "SKIP golem-notify.sh" \
        "Already-installed hook should be skipped"
    assert_not_contains "$output" "INSTALLED hook:golem-notify.sh" \
        "Should not re-install existing hook"
}

# ============================================================================
# Run all tests
# ============================================================================

# Static analysis
run_test test_cp_uses_recursive_flag "claude-setup: all template cp commands use -r"
run_test test_skill_cp_is_recursive "claude-setup: skill cp uses -r flag"
run_test test_agent_cp_is_recursive "claude-setup: agent cp uses -r flag"
run_test test_production_has_buildbound_gate "claude-setup: production uses _buildbound_needs_install gate"
run_test test_no_stamp_machinery "claude-setup: #574 stamp machinery removed"
run_test test_librarian_offline_install_present "claude-setup: librarian offline marketplace install present"

# Functional — basic installation
run_test test_flat_skills_install "install: flat extra skills copy correctly"
run_test test_agents_install "install: extra agents copy correctly"

# Functional — subdirectory regression
run_test test_skill_with_subdir_installs "install: skill with subdirectory copies recursively"
run_test test_subdir_skill_does_not_block_agents "install: subdir skill does not block agent installation"

# Functional — idempotency
run_test test_already_installed_skills_skipped "install: already-installed skills are skipped"
run_test test_already_installed_agents_skipped "install: already-installed agents are skipped"

# Functional — build-bound docker-development (absent-only)
run_test test_buildbound_docker_installs_then_skips "build-bound: docker-development installs then skips"
run_test test_buildbound_refresh_rewrites "build-bound: --refresh rewrites docker-development"

# Functional — hooks
run_test test_hooks_install_executable "install: hooks install with executable bit restored"
run_test test_already_installed_hooks_skipped "install: already-installed hooks are skipped"

# Generate test report
generate_report
