#!/usr/bin/env bash
# @tier: merge,weekly
# Test Claude Code librarian plugins + build-bound skills installation
#
# The general-purpose skills/agents ship as the librarian plugin marketplace,
# fetched at build as a cosign-verified release tarball to /opt/librarian at a
# pinned LIBRARIAN_REF and installed offline at runtime by claude-setup (issues
# #608/#671, epic #607). The build-bound skills (container-environment,
# cloud-infrastructure, docker-development) stay in this repo and still install.
# The #574 bake/stamp pipeline is removed.
#
# Tests:
# - librarian marketplace installed to /opt/librarian with a valid manifest
# - LIBRARIAN_REF build arg pins the version (signed release tag, verified)
# - an unsigned/pre-v0.4.0 ref fails the build closed (signature enforcement)
# - claude-setup registers the local marketplace offline + installs the plugins
# - claude-setup no longer references the #574 stamp machinery
# - Build-bound skill/hook templates still staged
# - enabled-features.conf contains cloud/docker flags

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

# Test: librarian marketplace installed + build-bound templates staged at build time
test_librarian_and_buildbound_staged() {
    local image="test-skills-agents-$$"
    echo "Building image with INCLUDE_DEV_TOOLS=true"

    assert_build_succeeds "Dockerfile" \
        --build-arg PROJECT_PATH=. \
        --build-arg PROJECT_NAME=test-skills-agents \
        --build-arg INCLUDE_DEV_TOOLS=true \
        --build-arg INCLUDE_NODE=true \
        -t "$image"

    # --- librarian marketplace installed to a durable image path ---
    assert_dir_in_image "$image" "/opt/librarian"
    assert_file_in_image "$image" "/opt/librarian/.claude-plugin/marketplace.json"
    # The 3 plugins are present as on-disk sources for the local marketplace.
    assert_dir_in_image "$image" "/opt/librarian/plugins/dev-core"
    assert_dir_in_image "$image" "/opt/librarian/plugins/review-audit"
    assert_dir_in_image "$image" "/opt/librarian/plugins/workflow"
    # No .git dir: the tree comes from the verified release tarball (a
    # `git archive`), not a clone, so a local marketplace has only the working
    # tree.
    assert_command_in_container "$image" \
        "test ! -d /opt/librarian/.git && echo 'no-git'" \
        "no-git"

    # --- Build-bound skill templates still staged (the only skills left here
    #     after #611 removed the migrated artifacts) ---
    assert_dir_in_image "$image" "/etc/container/config/claude-templates/skills"
    assert_file_in_image "$image" "/etc/container/config/claude-templates/skills/docker-development/SKILL.md"
    assert_file_in_image "$image" "/etc/container/config/claude-templates/skills/cloud-infrastructure/SKILL.md"
    assert_file_in_image "$image" "/etc/container/config/claude-templates/skills/container-environment/SKILL.md"

    # --- The general-purpose skills/agents and the golem-notify hook migrated to
    #     the librarian plugins (#611); they must NOT be staged here anymore ---
    assert_command_in_container "$image" \
        "test ! -e /etc/container/config/claude-templates/hooks/golem-notify.sh && echo 'gone'" \
        "gone"
    assert_command_in_container "$image" \
        "test ! -d /etc/container/config/claude-templates/agents && echo 'gone'" \
        "gone"

    # --- The #574 content stamp is NOT written anymore ---
    assert_command_in_container "$image" \
        "test ! -f /etc/container/config/claude-templates/.stamp && echo 'no-stamp'" \
        "no-stamp"
}

# Test: LIBRARIAN_REF build arg pins the version (override respected + verified)
test_librarian_ref_pinned() {
    local image="test-skills-librarian-ref-$$"

    # Pin an explicit *signed* release tag (v0.4.0+). The ref must resolve to a
    # release carrying a librarian-<ver>.tar.gz.sigstore.json bundle or the
    # build fails closed (see test_librarian_unsigned_fails_closed).
    assert_build_succeeds "Dockerfile" \
        --build-arg PROJECT_PATH=. \
        --build-arg PROJECT_NAME=test-librarian-ref \
        --build-arg INCLUDE_DEV_TOOLS=true \
        --build-arg INCLUDE_NODE=true \
        --build-arg "LIBRARIAN_REF=v0.4.0" \
        -t "$image"

    # The verified marketplace manifest names the librarian marketplace.
    assert_command_in_container "$image" \
        "grep -q '\"name\": \"librarian\"' /opt/librarian/.claude-plugin/marketplace.json && echo 'found'" \
        "found"
}

# Test: an unsigned / pre-signing ref fails the build closed (#671).
# v0.3.0 is a real librarian tag published *before* release signing (v0.4.0),
# so it has no librarian-<ver>.tar.gz.sigstore.json asset. The build must abort
# rather than silently install an unverified marketplace.
test_librarian_unsigned_fails_closed() {
    local image="test-skills-librarian-unsigned-$$"

    assert_build_fails "Dockerfile" \
        --build-arg PROJECT_PATH=. \
        --build-arg PROJECT_NAME=test-librarian-unsigned \
        --build-arg INCLUDE_DEV_TOOLS=true \
        --build-arg INCLUDE_NODE=true \
        --build-arg "LIBRARIAN_REF=v0.3.0" \
        -t "$image"
}

# Test: librarian marketplace manifest is valid and names the 3 plugins
test_librarian_manifest_plugins() {
    local image="${IMAGE_TO_TEST:-test-skills-agents-$$}"

    assert_command_in_container "$image" \
        "grep -q 'dev-core' /opt/librarian/.claude-plugin/marketplace.json && echo 'found'" \
        "found"
    assert_command_in_container "$image" \
        "grep -q 'review-audit' /opt/librarian/.claude-plugin/marketplace.json && echo 'found'" \
        "found"
    assert_command_in_container "$image" \
        "grep -q 'workflow' /opt/librarian/.claude-plugin/marketplace.json && echo 'found'" \
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

    # Verify claude-setup installs the librarian plugins from the local marketplace
    assert_command_in_container "$image" \
        "grep -q '/opt/librarian' /usr/local/bin/claude-setup && echo 'found'" \
        "found"

    # Verify it registers the local marketplace (offline, no auth)
    assert_command_in_container "$image" \
        "grep -q 'plugin marketplace add' /usr/local/bin/claude-setup && echo 'found'" \
        "found"

    # Verify it installs librarian-scoped plugins (plugin@librarian)
    assert_command_in_container "$image" \
        "grep -qF 'plugin install \"\${plugin}@\${LIBRARIAN_MARKETPLACE}\"' /usr/local/bin/claude-setup && echo 'found'" \
        "found"

    # Verify it still references the build-bound templates directory
    assert_command_in_container "$image" \
        "grep -q 'claude-templates' /usr/local/bin/claude-setup && echo 'found'" \
        "found"

    # Verify it handles the build-bound skills
    assert_command_in_container "$image" \
        "grep -q 'container-environment' /usr/local/bin/claude-setup && echo 'found'" \
        "found"
    assert_command_in_container "$image" \
        "grep -q 'cloud-infrastructure' /usr/local/bin/claude-setup && echo 'found'" \
        "found"
    assert_command_in_container "$image" \
        "grep -q 'docker-development' /usr/local/bin/claude-setup && echo 'found'" \
        "found"
}

# Test: claude-setup no longer references the #574 stamp machinery
test_claude_setup_no_stamp_machinery() {
    local image="${IMAGE_TO_TEST:-test-skills-agents-$$}"

    # grep returns 1 (no match) → invert to 'gone' so the assertion passes only
    # when the stamp machinery is absent.
    assert_command_in_container "$image" \
        "grep -q '_bundled_needs_sync\\|template-stamp\\|STAGED_STAMP' /usr/local/bin/claude-setup || echo 'gone'" \
        "gone"
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

# Test: Override vars persisted in enabled-features.conf
test_override_vars_persisted() {
    local image="test-skills-override-persist-$$"

    assert_build_succeeds "Dockerfile" \
        --build-arg PROJECT_PATH=. \
        --build-arg PROJECT_NAME=test-override-persist \
        --build-arg INCLUDE_DEV_TOOLS=true \
        --build-arg INCLUDE_NODE=true \
        --build-arg "CLAUDE_SKILLS=git-workflow,code-quality" \
        --build-arg "CLAUDE_AGENTS=debugger" \
        -t "$image"

    # Verify override vars are persisted. persist-feature-flags.sh quotes the
    # values (CLAUDE_SKILLS_DEFAULT="git-workflow,code-quality"), so match an
    # optional leading quote.
    assert_command_in_container "$image" \
        "grep 'CLAUDE_SKILLS_DEFAULT=\"\\?git-workflow,code-quality' /etc/container/config/enabled-features.conf && echo 'found'" \
        "found"

    assert_command_in_container "$image" \
        "grep 'CLAUDE_AGENTS_DEFAULT=\"\\?debugger' /etc/container/config/enabled-features.conf && echo 'found'" \
        "found"

    # Unset vars should get __UNSET__ sentinel
    assert_command_in_container "$image" \
        "grep 'CLAUDE_PLUGINS_DEFAULT=\"\\?__UNSET__' /etc/container/config/enabled-features.conf && echo 'found'" \
        "found"

    assert_command_in_container "$image" \
        "grep 'CLAUDE_MCPS_DEFAULT=\"\\?__UNSET__' /etc/container/config/enabled-features.conf && echo 'found'" \
        "found"

    # CLAUDE_LIBRARIAN_PLUGINS unset at build → __UNSET__ sentinel persisted
    assert_command_in_container "$image" \
        "grep 'CLAUDE_LIBRARIAN_PLUGINS_DEFAULT=\"\\?__UNSET__' /etc/container/config/enabled-features.conf && echo 'found'" \
        "found"
}

# Test: CLAUDE_LIBRARIAN_PLUGINS build override persists to enabled-features.conf
test_librarian_plugins_override_persisted() {
    local image="test-skills-librarian-override-$$"

    assert_build_succeeds "Dockerfile" \
        --build-arg PROJECT_PATH=. \
        --build-arg PROJECT_NAME=test-librarian-override \
        --build-arg INCLUDE_DEV_TOOLS=true \
        --build-arg INCLUDE_NODE=true \
        --build-arg "CLAUDE_LIBRARIAN_PLUGINS=dev-core,workflow" \
        -t "$image"

    # persist-feature-flags.sh quotes the value; match an optional leading quote.
    assert_command_in_container "$image" \
        "grep 'CLAUDE_LIBRARIAN_PLUGINS_DEFAULT=\"\\?dev-core,workflow' /etc/container/config/enabled-features.conf && echo 'found'" \
        "found"
}

# Test: claude-setup contains override helper functions
test_claude_setup_has_override_helpers() {
    local image="${IMAGE_TO_TEST:-test-skills-agents-$$}"

    assert_command_in_container "$image" \
        "grep -q '_resolve_override_list' /usr/local/bin/claude-setup && echo 'found'" \
        "found"

    assert_command_in_container "$image" \
        "grep -q '_is_in_list' /usr/local/bin/claude-setup && echo 'found'" \
        "found"

    assert_command_in_container "$image" \
        "grep -q 'CLAUDE_PLUGINS' /usr/local/bin/claude-setup && echo 'found'" \
        "found"

    # CLAUDE_LIBRARIAN_PLUGINS replaced the per-agent CLAUDE_AGENTS override for
    # the migrated artifacts (now installed as librarian plugins).
    assert_command_in_container "$image" \
        "grep -q 'CLAUDE_LIBRARIAN_PLUGINS' /usr/local/bin/claude-setup && echo 'found'" \
        "found"
}

# Run all tests
run_test test_librarian_and_buildbound_staged "librarian installed + build-bound templates staged at build time"
run_test test_librarian_manifest_plugins "librarian manifest names the 3 plugins"
run_test test_claude_setup_has_skills_section "claude-setup installs librarian plugins + build-bound skills"
run_test test_claude_setup_no_stamp_machinery "claude-setup no longer references #574 stamp machinery"
run_test test_claude_setup_verify_output "claude-setup verify output lists skills and agents"
run_test test_claude_setup_has_override_helpers "claude-setup has component override helpers"

# Skip tests that require building new images if using pre-built image
if [ -z "${IMAGE_TO_TEST:-}" ]; then
    run_test test_librarian_ref_pinned "LIBRARIAN_REF build arg pins the marketplace version"
    run_test test_librarian_unsigned_fails_closed "unsigned/pre-v0.4.0 LIBRARIAN_REF fails the build closed"
    run_test test_librarian_plugins_override_persisted "CLAUDE_LIBRARIAN_PLUGINS override persisted"
    run_test test_features_config_cloud_flags "enabled-features.conf contains cloud/docker flags"
    run_test test_override_vars_persisted "Override vars persisted in enabled-features.conf"
fi

# Generate test report
generate_report
