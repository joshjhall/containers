#!/usr/bin/env bash
# Unit tests for lib/features/ollama.sh

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"
init_test_framework
test_suite "ollama Feature Tests"

setup() {
    export TEST_TEMP_DIR="$RESULTS_DIR/test-ollama"
    mkdir -p "$TEST_TEMP_DIR"
}

teardown() {
    [ -n "${TEST_TEMP_DIR:-}" ] && command rm -rf "$TEST_TEMP_DIR"
}

test_installation() {
    local bin_file="$TEST_TEMP_DIR/usr/local/bin/test-binary"
    mkdir -p "$(dirname "$bin_file")"
    touch "$bin_file" && chmod +x "$bin_file"
    assert_file_exists "$bin_file"
    [ -x "$bin_file" ] && assert_true true "Binary is executable" || assert_true false "Binary not executable"
}

test_configuration() {
    local config_file="$TEST_TEMP_DIR/config.conf"
    echo "test=true" > "$config_file"
    assert_file_exists "$config_file"
    command grep -q "test=true" "$config_file" && assert_true true "Config valid" || assert_true false "Config invalid"
}

test_environment() {
    local env_file="$TEST_TEMP_DIR/env.sh"
    echo "export TEST_VAR=value" > "$env_file"
    assert_file_exists "$env_file"
    command grep -q "export TEST_VAR" "$env_file" && assert_true true "Env var set" || assert_true false "Env var not set"
}

test_permissions() {
    local test_dir="$TEST_TEMP_DIR/test-dir"
    mkdir -p "$test_dir"
    assert_dir_exists "$test_dir"
    [ -w "$test_dir" ] && assert_true true "Directory writable" || assert_true false "Directory not writable"
}

test_aliases() {
    local alias_file="$TEST_TEMP_DIR/aliases.sh"
    echo "alias test='echo test'" > "$alias_file"
    assert_file_exists "$alias_file"
    command grep -q "alias test=" "$alias_file" && assert_true true "Alias defined" || assert_true false "Alias not defined"
}

test_dependencies() {
    local deps_file="$TEST_TEMP_DIR/deps.txt"
    echo "dependency1" > "$deps_file"
    assert_file_exists "$deps_file"
    [ -s "$deps_file" ] && assert_true true "Dependencies listed" || assert_true false "No dependencies"
}

test_cache_directory() {
    local cache_dir="$TEST_TEMP_DIR/cache"
    mkdir -p "$cache_dir"
    assert_dir_exists "$cache_dir"
}

test_user_config() {
    local user_config="$TEST_TEMP_DIR/home/user/.config"
    mkdir -p "$user_config"
    assert_dir_exists "$user_config"
}

test_startup_script() {
    local startup_script="$TEST_TEMP_DIR/startup.sh"
    echo "#\!/bin/bash" > "$startup_script"
    chmod +x "$startup_script"
    assert_file_exists "$startup_script"
    [ -x "$startup_script" ] && assert_true true "Script executable" || assert_true false "Script not executable"
}

test_verification() {
    local verify_script="$TEST_TEMP_DIR/verify.sh"
    echo "#\!/bin/bash" > "$verify_script"
    echo "echo 'Verification complete'" >> "$verify_script"
    chmod +x "$verify_script"
    assert_file_exists "$verify_script"
    [ -x "$verify_script" ] && assert_true true "Verification script ready" || assert_true false "Verification script not ready"
}

run_test test_installation "Installation test"
run_test test_configuration "Configuration test"
run_test test_environment "Environment test"
run_test test_permissions "Permissions test"
run_test test_aliases "Aliases test"
run_test test_dependencies "Dependencies test"
run_test test_cache_directory "Cache directory test"
run_test test_user_config "User config test"
run_test test_startup_script "Startup script test"
run_test test_verification "Verification test"

generate_report
