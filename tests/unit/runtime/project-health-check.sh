#!/usr/bin/env bash
# Unit tests for lib/runtime/40-project-health-check.sh
# Tests project gitignore/dockerignore health check startup script

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Project Health Check Tests"

# Path to the script under test
HEALTH_CHECK_SCRIPT="$(dirname "${BASH_SOURCE[0]}")/../../../lib/runtime/40-project-health-check.sh"

# ============================================================================
# Test Setup / Teardown
# ============================================================================

setup() {
    export TEST_TEMP_DIR="$RESULTS_DIR/test-project-health-check-$$"
    mkdir -p "$TEST_TEMP_DIR"

    # Create a mock project root with .git directory
    export PROJECT_ROOT="$TEST_TEMP_DIR/project"
    mkdir -p "$PROJECT_ROOT/.git"

    # Create a mock features config
    export ENABLED_FEATURES_FILE="$TEST_TEMP_DIR/enabled-features.conf"
    command cat > "$ENABLED_FEATURES_FILE" << 'EOF'
INCLUDE_DEV_TOOLS=false
EOF

    # Ensure skip is off
    unset SKIP_PROJECT_HEALTH_CHECK 2>/dev/null || true
}

teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
    unset PROJECT_ROOT ENABLED_FEATURES_FILE SKIP_PROJECT_HEALTH_CHECK 2>/dev/null || true
}

# Helper to run the health check script in a subshell
# HAVE_BINDFS=false prevents auto-detection of bindfs on the test host.
# HAVE_DEV_TOOLS is left unset so the script reads from ENABLED_FEATURES_FILE.
run_health_check() {
    (
        export PROJECT_ROOT ENABLED_FEATURES_FILE
        export SKIP_PROJECT_HEALTH_CHECK="${SKIP_PROJECT_HEALTH_CHECK:-false}"
        export HAVE_BINDFS=false
        unset HAVE_DEV_TOOLS 2>/dev/null || true
        source "$HEALTH_CHECK_SCRIPT"
    ) 2>/dev/null
}

# Helper to run with bindfs enabled
run_health_check_with_bindfs() {
    (
        export PROJECT_ROOT ENABLED_FEATURES_FILE
        export SKIP_PROJECT_HEALTH_CHECK="${SKIP_PROJECT_HEALTH_CHECK:-false}"
        export HAVE_BINDFS=true
        unset HAVE_DEV_TOOLS 2>/dev/null || true
        source "$HEALTH_CHECK_SCRIPT"
    ) 2>/dev/null
}

# ============================================================================
# Skip Condition Tests
# ============================================================================

test_skip_when_env_set() {
    export SKIP_PROJECT_HEALTH_CHECK=true
    run_health_check
    assert_file_not_exists "$PROJECT_ROOT/.gitignore" "Should not create .gitignore when skipped"
}

test_skip_when_no_git_dir() {
    command rm -rf "$PROJECT_ROOT/.git"
    run_health_check
    assert_file_not_exists "$PROJECT_ROOT/.gitignore" "Should not create .gitignore without .git/"
}

# ============================================================================
# Gitignore Creation Tests
# ============================================================================

test_creates_gitignore_when_missing() {
    run_health_check
    assert_file_exists "$PROJECT_ROOT/.gitignore" "Should create .gitignore"
}

test_appends_to_existing_gitignore() {
    echo "node_modules/" > "$PROJECT_ROOT/.gitignore"
    run_health_check
    assert_file_contains "$PROJECT_ROOT/.gitignore" "node_modules/" "Should preserve existing content"
    assert_file_contains "$PROJECT_ROOT/.gitignore" "^\*\*/\.env$" "Should add **/.env entry"
}

# ============================================================================
# Unconditional Entry Tests
# ============================================================================

test_unconditional_env_entries() {
    run_health_check
    assert_file_contains "$PROJECT_ROOT/.gitignore" "^\*\*/\.env$" "**/.env should be present"
    assert_file_contains "$PROJECT_ROOT/.gitignore" "^\*\*/\.env\.\*$" "**/.env.* should be present"
}

test_unconditional_negation_entry() {
    run_health_check
    assert_file_contains "$PROJECT_ROOT/.gitignore" "^!\*\*/\.env\.example$" "!**/.env.example should be present"
    assert_file_contains "$PROJECT_ROOT/.gitignore" "^!\*\*/\.env\.\*\.example$" "!**/.env.*.example should be present"
}

test_unconditional_os_entries() {
    run_health_check
    assert_file_contains "$PROJECT_ROOT/.gitignore" "^\.DS_Store$" ".DS_Store should be present"
    assert_file_contains "$PROJECT_ROOT/.gitignore" "^Thumbs\.db$" "Thumbs.db should be present"
}

# ============================================================================
# Idempotency Tests
# ============================================================================

test_idempotent_no_duplicates() {
    run_health_check
    run_health_check

    # Count occurrences of **/.env (exact line)
    local count
    count=$(/usr/bin/grep -cFx "**/.env" "$PROJECT_ROOT/.gitignore")
    assert_equals "1" "$count" "**/.env should appear exactly once"
}

test_idempotent_negation_no_duplicates() {
    run_health_check
    run_health_check

    local count
    count=$(/usr/bin/grep -cFx '!**/.env.example' "$PROJECT_ROOT/.gitignore")
    assert_equals "1" "$count" "!**/.env.example should appear exactly once"
}

test_existing_entry_not_duplicated() {
    echo "**/.env" > "$PROJECT_ROOT/.gitignore"
    run_health_check

    local count
    count=$(/usr/bin/grep -cFx "**/.env" "$PROJECT_ROOT/.gitignore")
    assert_equals "1" "$count" "Pre-existing **/.env should not be duplicated"
}

# ============================================================================
# Conditional: BINDFS Tests
# ============================================================================

test_fuse_hidden_added_with_bindfs() {
    run_health_check_with_bindfs
    assert_file_contains "$PROJECT_ROOT/.gitignore" "^\.fuse_hidden\*$" ".fuse_hidden* should be added when bindfs is available"
}

test_fuse_hidden_not_added_without_bindfs() {
    run_health_check
    assert_file_not_contains "$PROJECT_ROOT/.gitignore" "fuse_hidden" ".fuse_hidden* should NOT be added without bindfs"
}

# ============================================================================
# Conditional: DEV_TOOLS Tests
# ============================================================================

test_claude_entries_added_with_dev_tools() {
    command cat > "$ENABLED_FEATURES_FILE" << 'EOF'
INCLUDE_DEV_TOOLS=true
EOF
    run_health_check
    assert_file_contains "$PROJECT_ROOT/.gitignore" "^\.claude/settings\.local\.json$" ".claude/settings.local.json should be added"
    assert_file_contains "$PROJECT_ROOT/.gitignore" "^\.claude/memory/tmp/$" ".claude/memory/tmp/ should be added"
}

test_claude_entries_not_added_without_dev_tools() {
    run_health_check
    assert_file_not_contains "$PROJECT_ROOT/.gitignore" "\.claude/" "Claude entries should NOT be added without dev-tools"
}

test_fuse_hidden_added_with_dev_tools() {
    command cat > "$ENABLED_FEATURES_FILE" << 'EOF'
INCLUDE_DEV_TOOLS=true
EOF
    run_health_check
    assert_file_contains "$PROJECT_ROOT/.gitignore" "^\.fuse_hidden\*$" ".fuse_hidden* should be added with dev-tools"
}

# ============================================================================
# Dockerignore Tests
# ============================================================================

test_dockerignore_created_with_dockerfile() {
    /usr/bin/touch "$PROJECT_ROOT/Dockerfile"
    run_health_check
    assert_file_exists "$PROJECT_ROOT/.dockerignore" ".dockerignore should be created when Dockerfile exists"
}

test_dockerignore_created_with_compose_yml() {
    /usr/bin/touch "$PROJECT_ROOT/docker-compose.yml"
    run_health_check
    assert_file_exists "$PROJECT_ROOT/.dockerignore" ".dockerignore should be created when docker-compose.yml exists"
}

test_dockerignore_created_with_compose_yaml() {
    /usr/bin/touch "$PROJECT_ROOT/compose.yaml"
    run_health_check
    assert_file_exists "$PROJECT_ROOT/.dockerignore" ".dockerignore should be created when compose.yaml exists"
}

test_dockerignore_not_created_without_docker_files() {
    run_health_check
    assert_file_not_exists "$PROJECT_ROOT/.dockerignore" ".dockerignore should NOT be created without Docker files"
}

test_dockerignore_entries() {
    /usr/bin/touch "$PROJECT_ROOT/Dockerfile"
    run_health_check
    assert_file_contains "$PROJECT_ROOT/.dockerignore" "^\.git/$" ".git/ should be in .dockerignore"
    assert_file_contains "$PROJECT_ROOT/.dockerignore" "^\*\*/\.env$" "**/.env should be in .dockerignore"
    assert_file_contains "$PROJECT_ROOT/.dockerignore" "^\.claude/$" ".claude/ should be in .dockerignore"
}

test_dockerignore_appends_missing() {
    /usr/bin/touch "$PROJECT_ROOT/Dockerfile"
    echo ".git/" > "$PROJECT_ROOT/.dockerignore"
    run_health_check

    assert_file_contains "$PROJECT_ROOT/.dockerignore" "^\*\*/\.env$" "Should add missing **/.env"
    local count
    count=$(/usr/bin/grep -cFx ".git/" "$PROJECT_ROOT/.dockerignore")
    assert_equals "1" "$count" ".git/ should not be duplicated"
}

# ============================================================================
# Comment Block Tests
# ============================================================================

test_comment_marker_present() {
    run_health_check
    assert_file_contains "$PROJECT_ROOT/.gitignore" "Added by devcontainer health check" "Comment marker should be present"
}

test_section_label_present() {
    run_health_check
    assert_file_contains "$PROJECT_ROOT/.gitignore" "^# Environment and OS files$" "Section label should be present"
}

# ============================================================================
# Edge Case Tests
# ============================================================================

test_no_trailing_newline_handled() {
    # Write file without trailing newline
    printf "existing-entry" > "$PROJECT_ROOT/.gitignore"
    run_health_check

    # First line should still be intact
    assert_file_contains "$PROJECT_ROOT/.gitignore" "^existing-entry$" "Existing content should be preserved"
    assert_file_contains "$PROJECT_ROOT/.gitignore" "^\*\*/\.env$" "New entries should be added"
}

test_partial_match_not_false_positive() {
    # .env.production is NOT the same as **/.env
    echo ".env.production" > "$PROJECT_ROOT/.gitignore"
    run_health_check

    # **/.env should still be added (not a false positive from .env.production)
    local count
    count=$(/usr/bin/grep -cFx "**/.env" "$PROJECT_ROOT/.gitignore")
    assert_equals "1" "$count" "**/.env should be added despite .env.production existing"
}

# ============================================================================
# Run all tests
# ============================================================================

run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"

    setup
    run_test "$test_function" "$test_description"
    teardown
}

run_test_with_setup test_skip_when_env_set "Skip when SKIP_PROJECT_HEALTH_CHECK=true"
run_test_with_setup test_skip_when_no_git_dir "Skip when no .git/ directory"
run_test_with_setup test_creates_gitignore_when_missing "Creates .gitignore when missing"
run_test_with_setup test_appends_to_existing_gitignore "Appends to existing .gitignore"
run_test_with_setup test_unconditional_env_entries "Unconditional .env entries"
run_test_with_setup test_unconditional_negation_entry "Unconditional !.env.example entry"
run_test_with_setup test_unconditional_os_entries "Unconditional OS entries (.DS_Store, Thumbs.db)"
run_test_with_setup test_idempotent_no_duplicates "Idempotency: no duplicate entries"
run_test_with_setup test_idempotent_negation_no_duplicates "Idempotency: no duplicate negation entries"
run_test_with_setup test_existing_entry_not_duplicated "Pre-existing entry not duplicated"
run_test_with_setup test_fuse_hidden_added_with_bindfs "Conditional: .fuse_hidden* with bindfs"
run_test_with_setup test_fuse_hidden_not_added_without_bindfs "Conditional: no .fuse_hidden* without bindfs"
run_test_with_setup test_claude_entries_added_with_dev_tools "Conditional: Claude entries with dev-tools"
run_test_with_setup test_claude_entries_not_added_without_dev_tools "Conditional: no Claude entries without dev-tools"
run_test_with_setup test_fuse_hidden_added_with_dev_tools "Conditional: .fuse_hidden* with dev-tools"
run_test_with_setup test_dockerignore_created_with_dockerfile "Dockerignore created with Dockerfile"
run_test_with_setup test_dockerignore_created_with_compose_yml "Dockerignore created with docker-compose.yml"
run_test_with_setup test_dockerignore_created_with_compose_yaml "Dockerignore created with compose.yaml"
run_test_with_setup test_dockerignore_not_created_without_docker_files "Dockerignore not created without Docker files"
run_test_with_setup test_dockerignore_entries "Dockerignore has expected entries"
run_test_with_setup test_dockerignore_appends_missing "Dockerignore appends missing entries"
run_test_with_setup test_comment_marker_present "Comment marker present in output"
run_test_with_setup test_section_label_present "Section label present in output"
run_test_with_setup test_no_trailing_newline_handled "Handles file without trailing newline"
run_test_with_setup test_partial_match_not_false_positive "Partial match not a false positive"

# Generate test report
generate_report
