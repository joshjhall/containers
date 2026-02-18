#!/usr/bin/env bash
# Test Claude Code skills and agents installation
#
# This test verifies that skill and agent templates are staged at build time
# and that the claude-setup command includes the installation logic.
#
# Tests:
# - Skill/agent templates staged to /etc/container/config/claude-templates/
# - All expected template files exist
# - enabled-features.conf contains cloud/docker flags
# - Conditional skill templates present based on build flags
# - claude-setup script includes skills & agents installation section

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the test framework
source "$SCRIPT_DIR/../../framework.sh"

# Initialize the test framework
init_test_framework

# For standalone testing, we build from containers directory
export BUILD_CONTEXT="$CONTAINERS_DIR"

# Define test suite
test_suite "Claude Code Skills & Agents"

# Test: Templates staged at build time with dev-tools
test_templates_staged() {
    local image="test-skills-agents-$$"
    echo "Building image with INCLUDE_DEV_TOOLS=true"

    assert_build_succeeds "Dockerfile" \
        --build-arg PROJECT_PATH=. \
        --build-arg PROJECT_NAME=test-skills-agents \
        --build-arg INCLUDE_DEV_TOOLS=true \
        --build-arg INCLUDE_NODE=true \
        -t "$image"

    # Verify templates directory exists
    assert_dir_in_image "$image" "/etc/container/config/claude-templates"

    # Verify skill templates
    assert_dir_in_image "$image" "/etc/container/config/claude-templates/skills"
    assert_file_in_image "$image" "/etc/container/config/claude-templates/skills/container-environment/SKILL.md"
    assert_file_in_image "$image" "/etc/container/config/claude-templates/skills/git-workflow/SKILL.md"
    assert_file_in_image "$image" "/etc/container/config/claude-templates/skills/testing-patterns/SKILL.md"
    assert_file_in_image "$image" "/etc/container/config/claude-templates/skills/code-quality/SKILL.md"
    assert_file_in_image "$image" "/etc/container/config/claude-templates/skills/development-workflow/SKILL.md"
    assert_file_in_image "$image" "/etc/container/config/claude-templates/skills/error-handling/SKILL.md"
    assert_file_in_image "$image" "/etc/container/config/claude-templates/skills/documentation-authoring/SKILL.md"
    assert_file_in_image "$image" "/etc/container/config/claude-templates/skills/shell-scripting/SKILL.md"
    assert_file_in_image "$image" "/etc/container/config/claude-templates/skills/skill-authoring/SKILL.md"
    assert_file_in_image "$image" "/etc/container/config/claude-templates/skills/agent-authoring/SKILL.md"
    assert_file_in_image "$image" "/etc/container/config/claude-templates/skills/docker-development/SKILL.md"
    assert_file_in_image "$image" "/etc/container/config/claude-templates/skills/cloud-infrastructure/SKILL.md"

    # Verify agent templates
    assert_dir_in_image "$image" "/etc/container/config/claude-templates/agents"
    assert_file_in_image "$image" "/etc/container/config/claude-templates/agents/code-reviewer/code-reviewer.md"
    assert_file_in_image "$image" "/etc/container/config/claude-templates/agents/test-writer/test-writer.md"
    assert_file_in_image "$image" "/etc/container/config/claude-templates/agents/refactorer/refactorer.md"
    assert_file_in_image "$image" "/etc/container/config/claude-templates/agents/debugger/debugger.md"
}

# Test: Agent templates have correct YAML frontmatter
test_agent_frontmatter() {
    local image="${IMAGE_TO_TEST:-test-skills-agents-$$}"

    # Verify code-reviewer has name field
    assert_command_in_container "$image" \
        "grep -q 'name: code-reviewer' /etc/container/config/claude-templates/agents/code-reviewer/code-reviewer.md && echo 'found'" \
        "found"

    # Verify test-writer has name field
    assert_command_in_container "$image" \
        "grep -q 'name: test-writer' /etc/container/config/claude-templates/agents/test-writer/test-writer.md && echo 'found'" \
        "found"

    # Verify refactorer has name field
    assert_command_in_container "$image" \
        "grep -q 'name: refactorer' /etc/container/config/claude-templates/agents/refactorer/refactorer.md && echo 'found'" \
        "found"

    # Verify debugger has name field
    assert_command_in_container "$image" \
        "grep -q 'name: debugger' /etc/container/config/claude-templates/agents/debugger/debugger.md && echo 'found'" \
        "found"
}

# Test: Skill templates have correct YAML frontmatter
test_skill_frontmatter() {
    local image="${IMAGE_TO_TEST:-test-skills-agents-$$}"

    # Verify git-workflow has description
    assert_command_in_container "$image" \
        "grep -q 'description:' /etc/container/config/claude-templates/skills/git-workflow/SKILL.md && echo 'found'" \
        "found"

    # Verify testing-patterns has description
    assert_command_in_container "$image" \
        "grep -q 'description:' /etc/container/config/claude-templates/skills/testing-patterns/SKILL.md && echo 'found'" \
        "found"

    # Verify code-quality has description
    assert_command_in_container "$image" \
        "grep -q 'description:' /etc/container/config/claude-templates/skills/code-quality/SKILL.md && echo 'found'" \
        "found"
}

# Test: enabled-features.conf contains cloud/docker flags
test_features_config_cloud_flags() {
    local image="test-skills-cloud-flags-$$"

    assert_build_succeeds "Dockerfile" \
        --build-arg PROJECT_PATH=. \
        --build-arg PROJECT_NAME=test-skills-cloud \
        --build-arg INCLUDE_DEV_TOOLS=true \
        --build-arg INCLUDE_DOCKER=true \
        --build-arg INCLUDE_KUBERNETES=true \
        --build-arg INCLUDE_AWS=true \
        -t "$image"

    # Verify cloud/docker flags in enabled-features.conf
    assert_command_in_container "$image" \
        "grep 'INCLUDE_DOCKER=true' /etc/container/config/enabled-features.conf && echo 'found'" \
        "found"

    assert_command_in_container "$image" \
        "grep 'INCLUDE_KUBERNETES=true' /etc/container/config/enabled-features.conf && echo 'found'" \
        "found"

    assert_command_in_container "$image" \
        "grep 'INCLUDE_AWS=true' /etc/container/config/enabled-features.conf && echo 'found'" \
        "found"

    # Verify flags that were not set default to false
    assert_command_in_container "$image" \
        "grep 'INCLUDE_TERRAFORM=false' /etc/container/config/enabled-features.conf && echo 'found'" \
        "found"

    assert_command_in_container "$image" \
        "grep 'INCLUDE_GCLOUD=false' /etc/container/config/enabled-features.conf && echo 'found'" \
        "found"

    assert_command_in_container "$image" \
        "grep 'INCLUDE_CLOUDFLARE=false' /etc/container/config/enabled-features.conf && echo 'found'" \
        "found"
}

# Test: claude-setup script contains skills installation logic
test_claude_setup_has_skills_section() {
    local image="${IMAGE_TO_TEST:-test-skills-agents-$$}"

    # Verify claude-setup contains skills installation section
    assert_command_in_container "$image" \
        "grep -q 'Skills & Agents Installation' /usr/local/bin/claude-setup && echo 'found'" \
        "found"

    # Verify it references the templates directory
    assert_command_in_container "$image" \
        "grep -q 'claude-templates' /usr/local/bin/claude-setup && echo 'found'" \
        "found"

    # Verify it handles container-environment skill
    assert_command_in_container "$image" \
        "grep -q 'container-environment' /usr/local/bin/claude-setup && echo 'found'" \
        "found"

    # Verify it handles cloud-infrastructure skill
    assert_command_in_container "$image" \
        "grep -q 'cloud-infrastructure' /usr/local/bin/claude-setup && echo 'found'" \
        "found"

    # Verify it handles docker-development skill
    assert_command_in_container "$image" \
        "grep -q 'docker-development' /usr/local/bin/claude-setup && echo 'found'" \
        "found"
}

# Test: claude-setup verify output lists skills and agents
test_claude_setup_verify_output() {
    local image="${IMAGE_TO_TEST:-test-skills-agents-$$}"

    # Verify the setup complete message mentions skills and agents
    assert_command_in_container "$image" \
        "grep -q 'ls ~/.claude/skills/' /usr/local/bin/claude-setup && echo 'found'" \
        "found"

    assert_command_in_container "$image" \
        "grep -q 'ls ~/.claude/agents/' /usr/local/bin/claude-setup && echo 'found'" \
        "found"
}

# Run all tests
run_test test_templates_staged "Skill/agent templates staged at build time"
run_test test_agent_frontmatter "Agent templates have correct frontmatter"
run_test test_skill_frontmatter "Skill templates have correct frontmatter"
run_test test_claude_setup_has_skills_section "claude-setup has skills installation section"
run_test test_claude_setup_verify_output "claude-setup verify output lists skills and agents"

# Skip tests that require building new images if using pre-built image
if [ -z "${IMAGE_TO_TEST:-}" ]; then
    run_test test_features_config_cloud_flags "enabled-features.conf contains cloud/docker flags"
fi

# Generate test report
generate_report
