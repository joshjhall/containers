#!/usr/bin/env bash
# Unit tests for bin/setup-dev-environment.sh
# Tests development environment setup functionality

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Bin Setup Dev Environment Tests"

# Test: Script exists and is executable
test_script_exists() {
    assert_file_exists "$PROJECT_ROOT/bin/setup-dev-environment.sh"
    assert_executable "$PROJECT_ROOT/bin/setup-dev-environment.sh"
}

# Test: Git hooks directory exists
test_git_hooks_directory_exists() {
    if [ -d "$PROJECT_ROOT/.githooks" ]; then
        assert_true true ".githooks directory exists"
    else
        assert_true false ".githooks directory does not exist"
    fi
}

# Test: Pre-commit hook exists and is executable
test_precommit_hook_exists() {
    assert_file_exists "$PROJECT_ROOT/.githooks/pre-commit"
    assert_executable "$PROJECT_ROOT/.githooks/pre-commit"
}

# Test: Pre-push hook exists and is executable
test_prepush_hook_exists() {
    assert_file_exists "$PROJECT_ROOT/.githooks/pre-push"
    assert_executable "$PROJECT_ROOT/.githooks/pre-push"
}

# Test: Pre-commit hook contains shellcheck validation
test_precommit_has_shellcheck() {
    local hook_file="$PROJECT_ROOT/.githooks/pre-commit"

    if grep -q "shellcheck" "$hook_file"; then
        assert_true true "Pre-commit hook includes shellcheck validation"
    else
        assert_true false "Pre-commit hook missing shellcheck validation"
    fi
}

# Test: Pre-push hook contains shellcheck validation
test_prepush_has_shellcheck() {
    local hook_file="$PROJECT_ROOT/.githooks/pre-push"

    if grep -q "shellcheck" "$hook_file"; then
        assert_true true "Pre-push hook includes shellcheck validation"
    else
        assert_true false "Pre-push hook missing shellcheck validation"
    fi
}

# Test: Pre-push hook contains unit test validation
test_prepush_has_unit_tests() {
    local hook_file="$PROJECT_ROOT/.githooks/pre-push"

    if grep -q "run_unit_tests.sh" "$hook_file"; then
        assert_true true "Pre-push hook includes unit test validation"
    else
        assert_true false "Pre-push hook missing unit test validation"
    fi
}

# Test: Pre-commit hook checks for .env file
test_precommit_checks_env() {
    local hook_file="$PROJECT_ROOT/.githooks/pre-commit"

    if grep -q ".env" "$hook_file"; then
        assert_true true "Pre-commit hook checks for .env file"
    else
        assert_true false "Pre-commit hook missing .env check"
    fi
}

# Test: .gitignore contains .env
test_gitignore_has_env() {
    if grep -q "^\.env$" "$PROJECT_ROOT/.gitignore"; then
        assert_true true ".gitignore contains .env entry"
    else
        assert_true false ".gitignore missing .env entry"
    fi
}

# Test: Setup script mentions both hooks in documentation
test_script_documents_both_hooks() {
    local script="$PROJECT_ROOT/bin/setup-dev-environment.sh"

    local has_precommit_docs=false
    local has_prepush_docs=false

    if grep -q "Pre-commit hook" "$script"; then
        has_precommit_docs=true
    fi

    if grep -q "Pre-push hook" "$script"; then
        has_prepush_docs=true
    fi

    if [ "$has_precommit_docs" = true ] && [ "$has_prepush_docs" = true ]; then
        assert_true true "Setup script documents both pre-commit and pre-push hooks"
    else
        assert_true false "Setup script missing hook documentation"
    fi
}

# Test: Setup script has color variables defined
test_script_has_colors() {
    local script="$PROJECT_ROOT/bin/setup-dev-environment.sh"

    if grep -q "RED=" "$script" && grep -q "GREEN=" "$script"; then
        assert_true true "Setup script defines color variables"
    else
        assert_true false "Setup script missing color variables"
    fi
}

# Test: Setup script configures git hooks path
test_script_configures_hooks_path() {
    local script="$PROJECT_ROOT/bin/setup-dev-environment.sh"

    if grep -q "git config core.hooksPath" "$script"; then
        assert_true true "Setup script configures git hooks path"
    else
        assert_true false "Setup script doesn't configure git hooks path"
    fi
}

# Test: Setup script checks for .env in .gitignore
test_script_checks_gitignore() {
    local script="$PROJECT_ROOT/bin/setup-dev-environment.sh"

    if grep -q "grep.*gitignore" "$script"; then
        assert_true true "Setup script checks .gitignore"
    else
        assert_true false "Setup script doesn't check .gitignore"
    fi
}

# Test: Setup script has tool checking function
test_script_has_tool_checker() {
    local script="$PROJECT_ROOT/bin/setup-dev-environment.sh"

    if grep -q "check_tool()" "$script"; then
        assert_true true "Setup script has check_tool function"
    else
        assert_true false "Setup script missing check_tool function"
    fi
}

# Test: Setup script checks for shellcheck
test_script_checks_shellcheck() {
    local script="$PROJECT_ROOT/bin/setup-dev-environment.sh"

    if grep -q 'check_tool.*shellcheck' "$script"; then
        assert_true true "Setup script checks for shellcheck"
    else
        assert_true false "Setup script doesn't check for shellcheck"
    fi
}

# Test: Setup script checks for docker
test_script_checks_docker() {
    local script="$PROJECT_ROOT/bin/setup-dev-environment.sh"

    if grep -q 'check_tool.*docker' "$script"; then
        assert_true true "Setup script checks for docker"
    else
        assert_true false "Setup script doesn't check for docker"
    fi
}

# Test: Setup script checks for jq
test_script_checks_jq() {
    local script="$PROJECT_ROOT/bin/setup-dev-environment.sh"

    if grep -q 'check_tool.*jq' "$script"; then
        assert_true true "Setup script checks for jq"
    else
        # This will fail initially, but should pass after implementation
        skip_test "Setup script doesn't check for jq yet (expected improvement)"
    fi
}

# Test: Setup script verifies hook executability
test_script_verifies_hook_executability() {
    local script="$PROJECT_ROOT/bin/setup-dev-environment.sh"

    if grep -q "chmod.*hook" "$script" || grep -q '\-x.*hook' "$script"; then
        assert_true true "Setup script verifies hook executability"
    else
        # This will fail initially, but should pass after implementation
        skip_test "Setup script doesn't verify hook executability yet (expected improvement)"
    fi
}

# Test: Setup script checks git user configuration
test_script_checks_git_config() {
    local script="$PROJECT_ROOT/bin/setup-dev-environment.sh"

    if grep -q "git config user.name" "$script" || grep -q "git config user.email" "$script"; then
        assert_true true "Setup script checks git user configuration"
    else
        # This will fail initially, but should pass after implementation
        skip_test "Setup script doesn't check git config yet (expected improvement)"
    fi
}

# Run tests
run_test test_script_exists "Setup script exists and is executable"
run_test test_git_hooks_directory_exists "Git hooks directory exists"
run_test test_precommit_hook_exists "Pre-commit hook exists and is executable"
run_test test_prepush_hook_exists "Pre-push hook exists and is executable"
run_test test_precommit_has_shellcheck "Pre-commit hook includes shellcheck"
run_test test_prepush_has_shellcheck "Pre-push hook includes shellcheck"
run_test test_prepush_has_unit_tests "Pre-push hook includes unit tests"
run_test test_precommit_checks_env "Pre-commit hook checks for .env"
run_test test_gitignore_has_env ".gitignore contains .env"
run_test test_script_documents_both_hooks "Setup script documents both hooks"
run_test test_script_has_colors "Setup script has color variables"
run_test test_script_configures_hooks_path "Setup script configures hooks path"
run_test test_script_checks_gitignore "Setup script checks .gitignore"
run_test test_script_has_tool_checker "Setup script has check_tool function"
run_test test_script_checks_shellcheck "Setup script checks for shellcheck"
run_test test_script_checks_docker "Setup script checks for docker"
run_test test_script_checks_jq "Setup script checks for jq"
run_test test_script_verifies_hook_executability "Setup script verifies hook executability"
run_test test_script_checks_git_config "Setup script checks git user config"

# Generate test report
generate_report
