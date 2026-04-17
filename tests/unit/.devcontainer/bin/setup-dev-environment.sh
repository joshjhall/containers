#!/usr/bin/env bash
# Unit tests for .devcontainer/bin/setup-dev-environment.sh
# Tests development environment setup functionality

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Bin Setup Dev Environment Tests"

# Test: Script exists and is executable
test_script_exists() {
    assert_file_exists "$PROJECT_ROOT/.devcontainer/bin/setup-dev-environment.sh"
    assert_executable "$PROJECT_ROOT/.devcontainer/bin/setup-dev-environment.sh"
}

# Test: Lefthook config exists
test_lefthook_config_exists() {
    assert_file_exists "$PROJECT_ROOT/lefthook.yml"
}

# Test: Lefthook config has shellcheck hook
test_lefthook_has_shellcheck() {
    local config_file="$PROJECT_ROOT/lefthook.yml"

    if command grep -q "shellcheck" "$config_file"; then
        assert_true true "Lefthook config includes shellcheck"
    else
        assert_true false "Lefthook config missing shellcheck"
    fi
}

# Test: Lefthook config has unit tests in pre-push stage
test_lefthook_has_unit_tests() {
    local config_file="$PROJECT_ROOT/lefthook.yml"

    if command grep -q "unit-tests:" "$config_file" && command grep -q "pre-push:" "$config_file"; then
        assert_true true "Lefthook config includes unit tests on pre-push"
    else
        assert_true false "Lefthook config missing unit tests on pre-push"
    fi
}

# Test: Lefthook config has credential detection (gitleaks + detect-private-key)
test_lefthook_has_credential_detection() {
    local config_file="$PROJECT_ROOT/lefthook.yml"

    if command grep -q "gitleaks\|detect-private-key" "$config_file"; then
        assert_true true "Lefthook config includes credential detection"
    else
        assert_true false "Lefthook config missing credential detection"
    fi
}

# Test: Lefthook config prevents .env commit
test_lefthook_prevents_env_commit() {
    local config_file="$PROJECT_ROOT/lefthook.yml"

    if command grep -q "no-env-file\|\.env" "$config_file"; then
        assert_true true "Lefthook config prevents .env commit"
    else
        assert_true false "Lefthook config missing .env prevention"
    fi
}

# Test: .gitignore contains .env
test_gitignore_has_env() {
    if command grep -qF "**/.env" "$PROJECT_ROOT/.gitignore"; then
        assert_true true ".gitignore contains .env entry"
    else
        assert_true false ".gitignore missing .env entry"
    fi
}

# Test: Setup script uses lefthook install
test_script_uses_lefthook_install() {
    local script="$PROJECT_ROOT/.devcontainer/bin/setup-dev-environment.sh"

    if command grep -q "lefthook install" "$script"; then
        assert_true true "Setup script uses lefthook install"
    else
        assert_true false "Setup script doesn't use lefthook install"
    fi
}

# Test: Setup script installs both pre-commit and pre-push (lefthook install does both)
test_script_installs_hooks() {
    local script="$PROJECT_ROOT/.devcontainer/bin/setup-dev-environment.sh"

    if command grep -q "pre-commit.*pre-push\|lefthook install" "$script"; then
        assert_true true "Setup script installs both commit and push hooks via lefthook"
    else
        assert_true false "Setup script doesn't install lefthook hooks"
    fi
}

# Test: Setup script has color variables (sourced or defined)
test_script_has_colors() {
    local script="$PROJECT_ROOT/.devcontainer/bin/setup-dev-environment.sh"

    if command grep -q "colors.sh" "$script" || { command grep -q "RED=" "$script" && command grep -q "GREEN=" "$script"; }; then
        assert_true true "Setup script sources or defines color variables"
    else
        assert_true false "Setup script missing color variables"
    fi
}

# Test: Setup script checks .gitignore
test_script_checks_gitignore() {
    local script="$PROJECT_ROOT/.devcontainer/bin/setup-dev-environment.sh"

    if command grep -q "grep.*gitignore" "$script"; then
        assert_true true "Setup script checks .gitignore"
    else
        assert_true false "Setup script doesn't check .gitignore"
    fi
}

# Test: Setup script has tool checking function
test_script_has_tool_checker() {
    local script="$PROJECT_ROOT/.devcontainer/bin/setup-dev-environment.sh"

    if command grep -q "check_tool()" "$script"; then
        assert_true true "Setup script has check_tool function"
    else
        assert_true false "Setup script missing check_tool function"
    fi
}

# Test: Setup script checks for shellcheck
test_script_checks_shellcheck() {
    local script="$PROJECT_ROOT/.devcontainer/bin/setup-dev-environment.sh"

    if command grep -q 'check_tool.*shellcheck' "$script"; then
        assert_true true "Setup script checks for shellcheck"
    else
        assert_true false "Setup script doesn't check for shellcheck"
    fi
}

# Test: Setup script checks for docker
test_script_checks_docker() {
    local script="$PROJECT_ROOT/.devcontainer/bin/setup-dev-environment.sh"

    if command grep -q 'check_tool.*docker' "$script"; then
        assert_true true "Setup script checks for docker"
    else
        assert_true false "Setup script doesn't check for docker"
    fi
}

# Test: Setup script checks for lefthook
test_script_checks_lefthook() {
    local script="$PROJECT_ROOT/.devcontainer/bin/setup-dev-environment.sh"

    if command grep -q 'check_tool.*lefthook\|command -v lefthook' "$script"; then
        assert_true true "Setup script checks for lefthook"
    else
        assert_true false "Setup script doesn't check for lefthook"
    fi
}

# Test: Setup script checks git user configuration
test_script_checks_git_config() {
    local script="$PROJECT_ROOT/.devcontainer/bin/setup-dev-environment.sh"

    if command grep -q "git config user.name" "$script" || command grep -q "git config user.email" "$script"; then
        assert_true true "Setup script checks git user configuration"
    else
        assert_true false "Setup script doesn't check git config"
    fi
}

# Test: No .githooks directory (lefthook installs hooks directly into .git/hooks)
test_no_githooks_directory() {
    if [ ! -d "$PROJECT_ROOT/.githooks" ]; then
        assert_true true "No .githooks directory (lefthook manages .git/hooks directly)"
    else
        assert_true false ".githooks directory still exists (should use lefthook)"
    fi
}

# Test: No lingering pre-commit config (migrated to lefthook)
test_no_precommit_config() {
    if [ ! -f "$PROJECT_ROOT/.pre-commit-config.yaml" ]; then
        assert_true true "No .pre-commit-config.yaml (migrated to lefthook.yml)"
    else
        assert_true false ".pre-commit-config.yaml still exists (should be removed post-migration)"
    fi
}

# Run tests
run_test test_script_exists "Setup script exists and is executable"
run_test test_lefthook_config_exists "Lefthook config exists"
run_test test_lefthook_has_shellcheck "Lefthook config includes shellcheck"
run_test test_lefthook_has_unit_tests "Lefthook config includes unit tests on pre-push"
run_test test_lefthook_has_credential_detection "Lefthook config includes credential detection"
run_test test_lefthook_prevents_env_commit "Lefthook config prevents .env commit"
run_test test_gitignore_has_env ".gitignore contains .env"
run_test test_script_uses_lefthook_install "Setup script uses lefthook install"
run_test test_script_installs_hooks "Setup script installs lefthook hooks"
run_test test_script_has_colors "Setup script has color variables"
run_test test_script_checks_gitignore "Setup script checks .gitignore"
run_test test_script_has_tool_checker "Setup script has check_tool function"
run_test test_script_checks_shellcheck "Setup script checks for shellcheck"
run_test test_script_checks_docker "Setup script checks for docker"
run_test test_script_checks_lefthook "Setup script checks for lefthook"
run_test test_script_checks_git_config "Setup script checks git user config"
run_test test_no_githooks_directory "No .githooks directory (lefthook uses .git/hooks)"
run_test test_no_precommit_config "No .pre-commit-config.yaml (fully migrated)"

# Generate test report
generate_report
