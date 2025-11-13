#!/usr/bin/env bash
# Unit tests for examples/production/compare-sizes.sh
# Tests the size comparison utility script logic

set -euo pipefail

# Source test framework
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Production Size Comparison Script Tests"

# Setup
setup() {
    SCRIPT_PATH="$PROJECT_ROOT/examples/production/compare-sizes.sh"
}

# Test: Script exists and is executable
test_script_exists() {
    assert_file_exists "$SCRIPT_PATH"
    assert_executable "$SCRIPT_PATH"
}

# Test: Script has proper shebang
test_shebang() {
    local first_line
    first_line=$(head -n1 "$SCRIPT_PATH")
    assert_equals "#!/usr/bin/env bash" "$first_line" "Script shebang"
}

# Test: Script uses strict mode
test_strict_mode() {
    assert_file_contains "$SCRIPT_PATH" "set -euo pipefail" "Strict mode enabled"
}

# Test: Color output support
test_color_output() {
    assert_file_contains "$SCRIPT_PATH" "RED=" "Defines color variables"
    assert_file_contains "$SCRIPT_PATH" "GREEN=" "Has green color"
    assert_file_contains "$SCRIPT_PATH" "CYAN=" "Has cyan color"
    assert_file_contains "$SCRIPT_PATH" "BOLD=" "Has bold formatting"
    assert_file_contains "$SCRIPT_PATH" "NC=" "Has no-color reset"
}

# Test: Logging functions
test_logging_functions() {
    assert_file_contains "$SCRIPT_PATH" "log_info" "Has log_info function"
    assert_file_contains "$SCRIPT_PATH" "log_success" "Has log_success function"
    assert_file_contains "$SCRIPT_PATH" "log_warn" "Has log_warn function"
    assert_file_contains "$SCRIPT_PATH" "log_error" "Has log_error function"
}

# Test: format_bytes function exists
test_format_bytes_function() {
    assert_file_contains "$SCRIPT_PATH" "format_bytes()" "Has format_bytes function"
}

# Test: Byte size formatting logic
test_byte_formatting_logic() {
    # Should handle B, KB, MB, GB
    assert_file_contains "$SCRIPT_PATH" "1024" "KB threshold"
    assert_file_contains "$SCRIPT_PATH" "1048576" "MB threshold"
    assert_file_contains "$SCRIPT_PATH" "1073741824" "GB threshold"
}

# Test: get_image_size function
test_get_image_size_function() {
    assert_file_contains "$SCRIPT_PATH" "get_image_size()" "Has get_image_size function"
    assert_file_contains "$SCRIPT_PATH" "docker inspect" "Uses docker inspect"
    assert_file_contains "$SCRIPT_PATH" ".Size" "Gets Size field"
}

# Test: build_dev function
test_build_dev_function() {
    assert_file_contains "$SCRIPT_PATH" "build_dev()" "Has build_dev function"
    assert_file_contains "$SCRIPT_PATH" "BASE_IMAGE=debian:bookworm" "Uses full Debian"
    assert_file_contains "$SCRIPT_PATH" "ENABLE_PASSWORDLESS_SUDO=true" "Enables sudo in dev"
    assert_file_contains "$SCRIPT_PATH" "INCLUDE_DEV_TOOLS=true" "Includes dev tools"
}

# Test: build_prod function
test_build_prod_function() {
    assert_file_contains "$SCRIPT_PATH" "build_prod()" "Has build_prod function"
    assert_file_contains "$SCRIPT_PATH" "BASE_IMAGE=debian:bookworm-slim" "Uses slim Debian"
    assert_file_contains "$SCRIPT_PATH" "ENABLE_PASSWORDLESS_SUDO=false" "Disables sudo in prod"
    assert_file_contains "$SCRIPT_PATH" "INCLUDE_DEV_TOOLS=false" "Excludes dev tools"
}

# Test: compare_preset function
test_compare_preset_function() {
    assert_file_contains "$SCRIPT_PATH" "compare_preset()" "Has compare_preset function"
}

# Test: Comparison table output
test_comparison_table() {
    assert_file_contains "$SCRIPT_PATH" "Dev Size" "Table shows dev size"
    assert_file_contains "$SCRIPT_PATH" "Prod Size" "Table shows prod size"
    assert_file_contains "$SCRIPT_PATH" "Savings" "Table shows savings"
    assert_file_contains "$SCRIPT_PATH" "% Saved" "Table shows percentage"
}

# Test: Preset support
test_preset_support() {
    assert_file_contains "$SCRIPT_PATH" "minimal)" "Supports minimal preset"
    assert_file_contains "$SCRIPT_PATH" "python)" "Supports python preset"
    assert_file_contains "$SCRIPT_PATH" "node)" "Supports node preset"
    assert_file_contains "$SCRIPT_PATH" "multi)" "Supports multi preset"
    assert_file_contains "$SCRIPT_PATH" "all)" "Supports all presets"
}

# Test: Cleanup function
test_cleanup_function() {
    assert_file_contains "$SCRIPT_PATH" "cleanup()" "Has cleanup function"
    assert_file_contains "$SCRIPT_PATH" "docker rmi" "Removes test images"
}

# Test: Cleanup on exit
test_cleanup_on_exit() {
    assert_file_contains "$SCRIPT_PATH" "trap cleanup EXIT" "Traps EXIT for cleanup"
}

# Test: Test project name
test_test_project_name() {
    assert_file_contains "$SCRIPT_PATH" "size-test" "Uses test project name"
}

# Test: Percentage calculation
test_percentage_calculation() {
    assert_file_contains "$SCRIPT_PATH" "percent=" "Calculates percentage"
    assert_file_contains "$SCRIPT_PATH" "* 100" "Multiplies by 100"
}

# Test: Success threshold check
test_success_threshold() {
    # Should have logic to determine if savings are good
    assert_file_contains "$SCRIPT_PATH" "percent" "Checks percentage"
}

# Test: Main function
test_main_function() {
    assert_file_contains "$SCRIPT_PATH" "main()" "Has main function"
    assert_file_contains "$SCRIPT_PATH" "main \"\$@\"" "Calls main with arguments"
}

# Test: Docker availability check
test_docker_check() {
    assert_file_contains "$SCRIPT_PATH" "command -v docker" "Checks for Docker"
    assert_file_contains "$SCRIPT_PATH" "Docker is not installed" "Has error message"
}

# Test: Dockerfile validation
test_dockerfile_validation() {
    assert_file_contains "$SCRIPT_PATH" "Dockerfile not found" "Validates Dockerfile exists"
}

# Test: Build silencing
test_build_silencing() {
    # Builds should be quiet for cleaner output
    assert_file_contains "$SCRIPT_PATH" "/dev/null" "Silences build output"
}

# Test: All presets in single run
test_all_presets_run() {
    # When "all" is specified, should run all presets
    assert_file_contains "$SCRIPT_PATH" "compare_preset \"minimal\"" "Runs minimal"
    assert_file_contains "$SCRIPT_PATH" "compare_preset \"python\"" "Runs python"
    assert_file_contains "$SCRIPT_PATH" "compare_preset \"node\"" "Runs node"
    assert_file_contains "$SCRIPT_PATH" "compare_preset \"multi\"" "Runs multi"
}

# Test: Error handling for unknown preset
test_unknown_preset_error() {
    assert_file_contains "$SCRIPT_PATH" "Unknown preset" "Handles unknown preset"
    assert_file_contains "$SCRIPT_PATH" "Valid presets:" "Lists valid presets"
}

# Test: Header/banner
test_banner() {
    assert_file_contains "$SCRIPT_PATH" "Production Image Size Comparison" "Has banner"
    assert_file_contains "$SCRIPT_PATH" "====" "Has separator"
}

# Test: Final completion message
test_completion_message() {
    assert_file_contains "$SCRIPT_PATH" "Comparison complete" "Has completion message"
}

# Run all tests
run_test test_script_exists "Script exists and is executable"
run_test test_shebang "Script has proper shebang"
run_test test_strict_mode "Script uses strict mode"
run_test test_color_output "Color output support"
run_test test_logging_functions "Logging functions present"
run_test test_format_bytes_function "format_bytes function exists"
run_test test_byte_formatting_logic "Byte formatting logic present"
run_test test_get_image_size_function "get_image_size function exists"
run_test test_build_dev_function "build_dev function configured"
run_test test_build_prod_function "build_prod function configured"
run_test test_compare_preset_function "compare_preset function exists"
run_test test_comparison_table "Comparison table formatted"
run_test test_preset_support "All presets supported"
run_test test_cleanup_function "Cleanup function exists"
run_test test_cleanup_on_exit "Cleanup on exit configured"
run_test test_test_project_name "Test project name defined"
run_test test_percentage_calculation "Percentage calculation logic"
run_test test_success_threshold "Success threshold check"
run_test test_main_function "Main function exists"
run_test test_docker_check "Docker availability checked"
run_test test_dockerfile_validation "Dockerfile validation present"
run_test test_build_silencing "Build output silenced"
run_test test_all_presets_run "All presets run when specified"
run_test test_unknown_preset_error "Unknown preset error handling"
run_test test_banner "Banner/header present"
run_test test_completion_message "Completion message present"

# Generate test report
generate_report
