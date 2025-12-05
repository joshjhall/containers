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

# Test: Pre-commit config exists
test_precommit_config_exists() {
    assert_file_exists "$PROJECT_ROOT/.pre-commit-config.yaml"
}

# Test: Pre-commit config has shellcheck hook
test_precommit_has_shellcheck() {
    local config_file="$PROJECT_ROOT/.pre-commit-config.yaml"

    if grep -q "shellcheck" "$config_file"; then
        assert_true true "Pre-commit config includes shellcheck"
    else
        assert_true false "Pre-commit config missing shellcheck"
    fi
}

# Test: Pre-commit config has unit tests hook for pre-push
test_precommit_has_unit_tests() {
    local config_file="$PROJECT_ROOT/.pre-commit-config.yaml"

    if grep -q "unit-tests" "$config_file" && grep -q "pre-push" "$config_file"; then
        assert_true true "Pre-commit config includes unit tests on pre-push"
    else
        assert_true false "Pre-commit config missing unit tests on pre-push"
    fi
}

# Test: Pre-commit config has credential detection
test_precommit_has_credential_detection() {
    local config_file="$PROJECT_ROOT/.pre-commit-config.yaml"

    if grep -q "credential-patterns\|gitleaks" "$config_file"; then
        assert_true true "Pre-commit config includes credential detection"
    else
        assert_true false "Pre-commit config missing credential detection"
    fi
}

# Test: Pre-commit config prevents .env commit
test_precommit_prevents_env_commit() {
    local config_file="$PROJECT_ROOT/.pre-commit-config.yaml"

    if grep -q "no-env-file\|\.env" "$config_file"; then
        assert_true true "Pre-commit config prevents .env commit"
    else
        assert_true false "Pre-commit config missing .env prevention"
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

# Test: Setup script uses pre-commit install
test_script_uses_precommit_install() {
    local script="$PROJECT_ROOT/bin/setup-dev-environment.sh"

    if grep -q "pre-commit install" "$script"; then
        assert_true true "Setup script uses pre-commit install"
    else
        assert_true false "Setup script doesn't use pre-commit install"
    fi
}

# Test: Setup script installs pre-push hooks
test_script_installs_prepush() {
    local script="$PROJECT_ROOT/bin/setup-dev-environment.sh"

    if grep -q "pre-push" "$script"; then
        assert_true true "Setup script installs pre-push hooks"
    else
        assert_true false "Setup script doesn't install pre-push hooks"
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

# Test: Setup script checks .gitignore
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

# Test: Setup script checks for pre-commit
test_script_checks_precommit() {
    local script="$PROJECT_ROOT/bin/setup-dev-environment.sh"

    if grep -q 'check_tool.*pre-commit' "$script"; then
        assert_true true "Setup script checks for pre-commit"
    else
        assert_true false "Setup script doesn't check for pre-commit"
    fi
}

# Test: Setup script checks git user configuration
test_script_checks_git_config() {
    local script="$PROJECT_ROOT/bin/setup-dev-environment.sh"

    if grep -q "git config user.name" "$script" || grep -q "git config user.email" "$script"; then
        assert_true true "Setup script checks git user configuration"
    else
        assert_true false "Setup script doesn't check git config"
    fi
}

# Test: No .githooks directory (using pre-commit instead)
test_no_githooks_directory() {
    if [ ! -d "$PROJECT_ROOT/.githooks" ]; then
        assert_true true "No .githooks directory (using pre-commit framework)"
    else
        assert_true false ".githooks directory still exists (should use pre-commit)"
    fi
}

# Run tests
run_test test_script_exists "Setup script exists and is executable"
run_test test_precommit_config_exists "Pre-commit config exists"
run_test test_precommit_has_shellcheck "Pre-commit config includes shellcheck"
run_test test_precommit_has_unit_tests "Pre-commit config includes unit tests on pre-push"
run_test test_precommit_has_credential_detection "Pre-commit config includes credential detection"
run_test test_precommit_prevents_env_commit "Pre-commit config prevents .env commit"
run_test test_gitignore_has_env ".gitignore contains .env"
run_test test_script_uses_precommit_install "Setup script uses pre-commit install"
run_test test_script_installs_prepush "Setup script installs pre-push hooks"
run_test test_script_has_colors "Setup script has color variables"
run_test test_script_checks_gitignore "Setup script checks .gitignore"
run_test test_script_has_tool_checker "Setup script has check_tool function"
run_test test_script_checks_shellcheck "Setup script checks for shellcheck"
run_test test_script_checks_docker "Setup script checks for docker"
run_test test_script_checks_precommit "Setup script checks for pre-commit"
run_test test_script_checks_git_config "Setup script checks git user config"
run_test test_no_githooks_directory "No .githooks directory (using pre-commit)"

# Generate test report
generate_report
