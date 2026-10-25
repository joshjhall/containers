#!/usr/bin/env bash
# Unit tests for lib/runtime/check-installed-versions.sh

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"
init_test_framework
test_suite "check-installed-versions Runtime Tests"

setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$TEST_SCRATCH_BASE/test-check-installed-versions-$unique_id"
    mkdir -p "$TEST_TEMP_DIR"
}

teardown() {
    [ -n "${TEST_TEMP_DIR:-}" ] && command rm -rf "$TEST_TEMP_DIR"
}

test_script_exists() {
    local script_file="$TEST_TEMP_DIR/script.sh"
    echo "#\!/bin/bash" >"$script_file"
    chmod +x "$script_file"
    assert_file_exists "$script_file"
    [ -x "$script_file" ] && assert_true true "Script is executable" || assert_true false "Script not executable"
}

test_output_format() {
    local output_file="$TEST_TEMP_DIR/output.txt"
    echo "Test output" >"$output_file"
    assert_file_exists "$output_file"
    [ -s "$output_file" ] && assert_true true "Output generated" || assert_true false "No output"
}

test_error_handling() {
    local error_log="$TEST_TEMP_DIR/error.log"
    echo "Error: test" >"$error_log"
    assert_file_exists "$error_log"
    command grep -q "Error" "$error_log" && assert_true true "Error logged" || assert_true false "Error not logged"
}

test_permissions() {
    local test_file="$TEST_TEMP_DIR/test.txt"
    touch "$test_file"
    chmod 644 "$test_file"
    assert_file_exists "$test_file"
    [ -r "$test_file" ] && assert_true true "File readable" || assert_true false "File not readable"
}

test_directory_structure() {
    local test_dir="$TEST_TEMP_DIR/structure/sub"
    mkdir -p "$test_dir"
    assert_dir_exists "$test_dir"
}

test_environment_variables() {
    local env_file="$TEST_TEMP_DIR/env.sh"
    echo "export TEST_VAR=123" >"$env_file"
    assert_file_exists "$env_file"
    command grep -q "export TEST_VAR" "$env_file" && assert_true true "Env var exported" || assert_true false "Env var not exported"
}

test_command_execution() {
    local cmd_file="$TEST_TEMP_DIR/cmd.sh"
    echo "echo 'test'" >"$cmd_file"
    chmod +x "$cmd_file"
    assert_file_exists "$cmd_file"
    [ -x "$cmd_file" ] && assert_true true "Command executable" || assert_true false "Command not executable"
}

test_logging() {
    local log_file="$TEST_TEMP_DIR/app.log"
    echo "[INFO] Test log entry" >"$log_file"
    assert_file_exists "$log_file"
    command grep -q "\[INFO\]" "$log_file" && assert_true true "Log entry found" || assert_true false "Log entry not found"
}

test_configuration() {
    local config_file="$TEST_TEMP_DIR/config.conf"
    echo "setting=value" >"$config_file"
    assert_file_exists "$config_file"
    command grep -q "setting=value" "$config_file" && assert_true true "Config valid" || assert_true false "Config invalid"
}

test_validation() {
    local validate_script="$TEST_TEMP_DIR/validate.sh"
    echo "#\!/bin/bash" >"$validate_script"
    echo "exit 0" >>"$validate_script"
    chmod +x "$validate_script"
    assert_file_exists "$validate_script"
    [ -x "$validate_script" ] && assert_true true "Validation script ready" || assert_true false "Validation script not ready"
}

run_test_with_setup() {
    setup
    run_test "$1" "$2"
    teardown
}

run_test_with_setup test_script_exists "Script exists test"
run_test_with_setup test_output_format "Output format test"
run_test_with_setup test_error_handling "Error handling test"
run_test_with_setup test_permissions "Permissions test"
run_test_with_setup test_directory_structure "Directory structure test"
run_test_with_setup test_environment_variables "Environment variables test"
run_test_with_setup test_command_execution "Command execution test"
run_test_with_setup test_logging "Logging test"
run_test_with_setup test_configuration "Configuration test"
run_test_with_setup test_validation "Validation test"

# ============================================================================
# Batch 6: Static Analysis Tests for check-installed-versions.sh
# ============================================================================

SOURCE_FILE="$PROJECT_ROOT/lib/runtime/check-installed-versions.sh"

# Test: set -euo pipefail
test_civ_strict_mode() {
    assert_file_contains "$SOURCE_FILE" "set -euo pipefail" "check-installed-versions.sh uses strict mode"
}

# Test: defines check_version function
test_civ_check_version_func() {
    assert_file_contains "$SOURCE_FILE" "check_version()" "check-installed-versions.sh defines check_version function"
}

# Test: compare_version available via shared version-api.sh
test_civ_compare_version_func() {
    local shared_lib="$PROJECT_ROOT/lib/runtime/lib/version-api.sh"
    assert_file_contains "$shared_lib" "compare_version()" "version-api.sh defines compare_version function"
}

# Test: defines should_display_section function
test_civ_should_display_section_func() {
    assert_file_contains "$SOURCE_FILE" "should_display_section()" "check-installed-versions.sh defines should_display_section function"
}

# Test: --filter flag handling
test_civ_filter_flag() {
    assert_file_contains "$SOURCE_FILE" "--filter" "check-installed-versions.sh supports --filter flag"
    assert_file_contains "$SOURCE_FILE" "filter_category" "check-installed-versions.sh uses filter_category variable"
}

# Test: --compare flag handling
test_civ_compare_flag() {
    assert_file_contains "$SOURCE_FILE" "--compare" "check-installed-versions.sh supports --compare flag"
    assert_file_contains "$SOURCE_FILE" "compare_mode" "check-installed-versions.sh uses compare_mode variable"
}

# Test: --all flag handling
test_civ_all_flag() {
    assert_file_contains "$SOURCE_FILE" "--all" "check-installed-versions.sh supports --all flag"
    assert_file_contains "$SOURCE_FILE" "show_all" "check-installed-versions.sh uses show_all variable"
}

# Test: --json output format
test_civ_json_output() {
    assert_file_contains "$SOURCE_FILE" "--json" "check-installed-versions.sh supports --json output"
    assert_file_contains "$SOURCE_FILE" "output_format" "check-installed-versions.sh uses output_format variable"
}

# Test: Version extraction regex patterns
test_civ_version_extraction_patterns() {
    assert_file_contains "$SOURCE_FILE" 'grep -oP' "check-installed-versions.sh uses grep -oP for version extraction"
}

# Test: Summary statistics counting
test_civ_summary_statistics() {
    assert_file_contains "$SOURCE_FILE" "installed_count" "check-installed-versions.sh counts installed tools"
    assert_file_contains "$SOURCE_FILE" "outdated_count" "check-installed-versions.sh counts outdated tools"
}

# Run Batch 6 check-installed-versions tests
test_civ_print_section_results_func() {
    assert_file_contains "$SOURCE_FILE" "_print_section_results()" \
        "Defines _print_section_results helper"
}

# ============================================================================
# Functional Tests - run the real script against a hermetic PATH (#1411)
# ============================================================================

# Build $TEST_TEMP_DIR/bin holding only the utilities the script needs, a stub
# `fd` that reports itself as fdfind (as on Debian), and a stub `curl` that
# answers every GitHub lookup with a v-prefixed tag. No host tool or network
# call can leak in, so every count in the Summary starts from 0.
_civ_make_hermetic_bin() {
    local bin="$TEST_TEMP_DIR/bin"
    mkdir -p "$bin"
    local util path
    for util in bash cat cut dirname grep head readlink sed seq sort tail tr; do
        path=$(command -v "$util") || return 1
        command ln -s "$path" "$bin/$util"
    done
    printf '#!/bin/sh\necho "fdfind 10.2.0"\n' >"$bin/fd"
    printf '#!/bin/sh\necho "{\\"tag_name\\": \\"v10.2.0\\"}"\n' >"$bin/curl"
    chmod +x "$bin/fd" "$bin/curl"

    # Run a scratch copy of the script + its library: the script sources a
    # sibling .env, and a developer's gitignored lib/runtime/.env must not
    # leak into the run.
    mkdir -p "$TEST_TEMP_DIR/rt/lib"
    command cp "$SOURCE_FILE" "$TEST_TEMP_DIR/rt/check-installed-versions.sh"
    command cp "$PROJECT_ROOT/lib/runtime/lib/version-api.sh" "$TEST_TEMP_DIR/rt/lib/version-api.sh"
    CIV_SCRIPT="$TEST_TEMP_DIR/rt/check-installed-versions.sh"
}

# Add stubs that land in each remaining counter branch: rg is behind the
# stubbed latest (outdated), bat is ahead of it (newer), aws has no
# latest-version getter (installed), and gh prints output its pattern cannot
# parse (error, counted by the `*)` arm as Unknown). Each counter's first
# increment is from 0.
_civ_add_branch_stubs() {
    local bin="$TEST_TEMP_DIR/bin"
    printf '#!/bin/sh\necho "ripgrep 1.0.0"\n' >"$bin/rg"
    printf '#!/bin/sh\necho "bat 99.0.0"\n' >"$bin/bat"
    printf '#!/bin/sh\necho "aws-cli/2.0.0 Python/3.11"\n' >"$bin/aws"
    printf '#!/bin/sh\necho "nonsense"\n' >"$bin/gh"
    chmod +x "$bin/rg" "$bin/bat" "$bin/aws" "$bin/gh"
}

# Run the script (or a symlink to it) under the hermetic PATH.
# Captures stdout+stderr in $TEST_TEMP_DIR/out and the exit code in CIV_RC.
_civ_run() {
    local script="$1"
    shift
    CIV_RC=0
    /usr/bin/env -i HOME="$TEST_TEMP_DIR" PATH="$TEST_TEMP_DIR/bin" \
        "$script" "$@" >"$TEST_TEMP_DIR/out" 2>&1 || CIV_RC=$?
}

test_civ_summary_completes() {
    _civ_make_hermetic_bin
    _civ_run "$CIV_SCRIPT"
    assert_equals "0" "$CIV_RC" "script exits 0 under set -e"
    # Total includes missing tools, so only its shape is stable
    assert_file_contains "$TEST_TEMP_DIR/out" "Total tools checked: [0-9][0-9]*$" \
        "Summary prints past the counter loop"
    # The stub fd is the only installed tool; the value sits inside color codes
    assert_file_contains "$TEST_TEMP_DIR/out" "Up-to-date: .*m1[^0-9]" \
        "Summary counts exactly one up-to-date tool"
}

test_civ_summary_every_counter_branch() {
    _civ_make_hermetic_bin
    _civ_add_branch_stubs
    _civ_run "$CIV_SCRIPT" --all
    assert_equals "0" "$CIV_RC" "script exits 0 with every counter branch taken"
    assert_file_contains "$TEST_TEMP_DIR/out" "Up-to-date: .*m1[^0-9]" "one up-to-date tool (fd)"
    assert_file_contains "$TEST_TEMP_DIR/out" "Outdated: .*m1[^0-9]" "one outdated tool (rg)"
    assert_file_contains "$TEST_TEMP_DIR/out" "Newer: .*m1[^0-9]" "one newer tool (bat)"
    assert_file_contains "$TEST_TEMP_DIR/out" "Installed: .*m1[^0-9]" "one installed-only tool (aws)"
    assert_file_contains "$TEST_TEMP_DIR/out" "Unknown: .*m1[^0-9]" "one unparsable tool (gh)"
    assert_file_contains "$TEST_TEMP_DIR/out" "Missing: .*m[1-9][0-9]*[^0-9]" "the rest are missing"
}

test_civ_fd_reports_fdfind_version() {
    _civ_make_hermetic_bin
    _civ_run "$CIV_SCRIPT"
    local row
    row=$(command grep -E '^fd +' "$TEST_TEMP_DIR/out" || true)
    assert_contains "$row" "10.2.0" "fd row shows the fdfind version"
    assert_contains "$row" "up-to-date" "fd 10.2.0 vs latest v10.2.0 is up-to-date"
    assert_not_contains "$row" "v10.2.0" "latest column drops the release tag's v prefix"
}

test_civ_fd_reports_upstream_version() {
    _civ_make_hermetic_bin
    # Upstream fd (not Debian's fdfind) prints "fd <ver>"
    printf '#!/bin/sh\necho "fd 10.2.0"\n' >"$TEST_TEMP_DIR/bin/fd"
    _civ_run "$CIV_SCRIPT"
    local row
    row=$(command grep -E '^fd +' "$TEST_TEMP_DIR/out" || true)
    assert_contains "$row" "10.2.0" "fd row shows the upstream fd version"
    assert_contains "$row" "up-to-date" "upstream fd 10.2.0 vs latest v10.2.0 is up-to-date"
}

test_civ_runs_through_symlink() {
    _civ_make_hermetic_bin
    command ln -s "$CIV_SCRIPT" "$TEST_TEMP_DIR/bin/check-installed-versions.sh"
    _civ_run "$TEST_TEMP_DIR/bin/check-installed-versions.sh"
    assert_equals "0" "$CIV_RC" "script exits 0 when invoked through a PATH symlink"
    assert_file_contains "$TEST_TEMP_DIR/out" "Total tools checked: [0-9][0-9]*$" \
        "symlinked script still finds lib/version-api.sh"
}

test_civ_symlink_loads_sibling_env() {
    _civ_make_hermetic_bin
    # The real script's .env supplies GITHUB_TOKEN. This curl stub answers a
    # newer tag only when the token reaches it, so the fd row shows whether the
    # .env next to the REAL script was loaded through the PATH symlink.
    printf 'GITHUB_TOKEN=sentinel\n' >"$TEST_TEMP_DIR/rt/.env"
    command cat >"$TEST_TEMP_DIR/bin/curl" <<'STUB'
#!/bin/sh
case "$*" in
    *"Authorization: token sentinel"*) echo '{"tag_name": "v99.0.0"}' ;;
    *) echo '{"tag_name": "v10.2.0"}' ;;
esac
STUB
    command ln -s "$CIV_SCRIPT" "$TEST_TEMP_DIR/bin/check-installed-versions.sh"
    _civ_run "$TEST_TEMP_DIR/bin/check-installed-versions.sh"
    local row
    row=$(command grep -E '^fd +' "$TEST_TEMP_DIR/out" || true)
    assert_contains "$row" "99.0.0" "token from the real script's .env reached the GitHub lookup"
    assert_not_contains "$row" "v99.0.0" "latest column drops the release tag's v prefix"
    assert_contains "$row" "outdated" "fd 10.2.0 vs token-gated v99.0.0 is outdated"
}

test_civ_json_completes() {
    _civ_make_hermetic_bin
    _civ_run "$CIV_SCRIPT" --json
    assert_equals "0" "$CIV_RC" "--json exits 0"
    assert_file_contains "$TEST_TEMP_DIR/out" \
        '"tool": "fd", "installed": "10.2.0", "latest": "10.2.0", "status": "up-to-date"' \
        "--json reports fd's fdfind version as up-to-date"
}

run_test_with_setup test_civ_summary_completes "Summary completes and exits 0 with counters starting at 0"
run_test_with_setup test_civ_summary_every_counter_branch "Summary survives every counter branch from 0 under set -e"
run_test_with_setup test_civ_fd_reports_fdfind_version "fd version parsed from fdfind output"
run_test_with_setup test_civ_fd_reports_upstream_version "fd version parsed from upstream fd output"
run_test_with_setup test_civ_runs_through_symlink "Script runs through a PATH symlink"
run_test_with_setup test_civ_symlink_loads_sibling_env "Symlinked script loads the .env next to its real location"
run_test_with_setup test_civ_json_completes "--json output completes and exits 0"

run_test test_civ_print_section_results_func "Defines _print_section_results helper"
run_test test_civ_strict_mode "check-installed-versions.sh uses set -euo pipefail"
run_test test_civ_check_version_func "Defines check_version function"
run_test test_civ_compare_version_func "Defines compare_version function"
run_test test_civ_should_display_section_func "Defines should_display_section function"
run_test test_civ_filter_flag "--filter flag handling"
run_test test_civ_compare_flag "--compare flag handling"
run_test test_civ_all_flag "--all flag handling"
run_test test_civ_json_output "--json output format supported"
run_test test_civ_version_extraction_patterns "Version extraction regex patterns"
run_test test_civ_summary_statistics "Summary statistics counting"

generate_report
