#!/usr/bin/env bash
# Unit tests for examples/production/build-prod.sh
# Tests the production build helper script logic

set -euo pipefail

# Source test framework
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Production Build Helper Script Tests"

# Setup - source the script functions without executing main
setup() {
    # Source the script to get its functions
    # We'll mock the docker command
    SCRIPT_PATH="$PROJECT_ROOT/examples/production/build-prod.sh"
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

# Test: Help text is available
test_help_available() {
    # Should have usage function
    assert_file_contains "$SCRIPT_PATH" "usage()" "Has usage function"
    assert_file_contains "$SCRIPT_PATH" "Usage:" "Has usage documentation"
}

# Test: Presets are documented
test_presets_documented() {
    assert_file_contains "$SCRIPT_PATH" "minimal" "Minimal preset documented"
    assert_file_contains "$SCRIPT_PATH" "python" "Python preset documented"
    assert_file_contains "$SCRIPT_PATH" "node" "Node preset documented"
    assert_file_contains "$SCRIPT_PATH" "custom" "Custom preset documented"
}

# Test: Production base args are defined
test_production_base_args() {
    assert_file_contains "$SCRIPT_PATH" "BASE_IMAGE=debian:trixie-slim" "Uses slim base"
    assert_file_contains "$SCRIPT_PATH" "ENABLE_PASSWORDLESS_SUDO=false" "Disables passwordless sudo"
    assert_file_contains "$SCRIPT_PATH" "INCLUDE_DEV_TOOLS=false" "Disables dev tools"
}

# Test: Minimal preset configuration
test_minimal_preset_config() {
    assert_file_contains "$SCRIPT_PATH" "minimal)" "Has minimal preset"
    assert_file_contains "$SCRIPT_PATH" "INCLUDE_PYTHON=false" "Minimal excludes Python"
    assert_file_contains "$SCRIPT_PATH" "INCLUDE_NODE=false" "Minimal excludes Node"
}

# Test: Python preset configuration
test_python_preset_config() {
    assert_file_contains "$SCRIPT_PATH" "python)" "Has python preset"
    assert_file_contains "$SCRIPT_PATH" "INCLUDE_PYTHON=true" "Python preset includes Python"
    assert_file_contains "$SCRIPT_PATH" "INCLUDE_PYTHON_DEV=false" "Python preset excludes dev tools"
}

# Test: Node preset configuration
test_node_preset_config() {
    assert_file_contains "$SCRIPT_PATH" "node)" "Has node preset"
    assert_file_contains "$SCRIPT_PATH" "INCLUDE_NODE=true" "Node preset includes Node"
    assert_file_contains "$SCRIPT_PATH" "INCLUDE_NODE_DEV=false" "Node preset excludes dev tools"
}

# Test: Custom preset is available
test_custom_preset() {
    assert_file_contains "$SCRIPT_PATH" "custom)" "Has custom preset"
}

# Test: Argument parsing logic
test_argument_parsing() {
    assert_file_contains "$SCRIPT_PATH" "--arg)" "Handles --arg option"
    assert_file_contains "$SCRIPT_PATH" "--context)" "Handles --context option"
    assert_file_contains "$SCRIPT_PATH" "--help)" "Handles --help option"
}

# Test: Docker command construction
test_docker_command_construction() {
    assert_file_contains "$SCRIPT_PATH" "docker build" "Constructs docker build command"
    assert_file_contains "$SCRIPT_PATH" "--build-arg" "Uses build arguments"
    assert_file_contains "$SCRIPT_PATH" "-t" "Sets image tag"
    assert_file_contains "$SCRIPT_PATH" "-f" "Specifies Dockerfile"
}

# Test: Image tag format
test_image_tag_format() {
    # Tag format should be: project:preset-prod
    assert_file_contains "$SCRIPT_PATH" "minimal-prod" "Minimal tag suffix"
    assert_file_contains "$SCRIPT_PATH" "python-prod" "Python tag suffix"
    assert_file_contains "$SCRIPT_PATH" "node-prod" "Node tag suffix"
    assert_file_contains "$SCRIPT_PATH" "custom-prod" "Custom tag suffix"
}

# Test: Build success message
test_build_success_message() {
    assert_file_contains "$SCRIPT_PATH" "Build completed successfully" "Has success message"
    assert_file_contains "$SCRIPT_PATH" "Image:" "Shows image name"
    assert_file_contains "$SCRIPT_PATH" "Image Size:" "Shows image size"
}

# Test: Build failure handling
test_build_failure_handling() {
    assert_file_contains "$SCRIPT_PATH" "Build failed" "Has failure message"
    assert_file_contains "$SCRIPT_PATH" "exit 1" "Exits on failure"
}

# Test: Next steps suggestions
test_next_steps() {
    assert_file_contains "$SCRIPT_PATH" "Next steps:" "Has next steps section"
    assert_file_contains "$SCRIPT_PATH" "docker run" "Suggests running container"
    assert_file_contains "$SCRIPT_PATH" "docker inspect" "Suggests inspecting image"
}

# Test: Color output support
test_color_output() {
    assert_file_contains "$SCRIPT_PATH" "RED=" "Defines color variables"
    assert_file_contains "$SCRIPT_PATH" "GREEN=" "Has green color"
    assert_file_contains "$SCRIPT_PATH" "YELLOW=" "Has yellow color"
    assert_file_contains "$SCRIPT_PATH" "BLUE=" "Has blue color"
    assert_file_contains "$SCRIPT_PATH" "NC=" "Has no-color reset"
}

# Test: Logging functions
test_logging_functions() {
    assert_file_contains "$SCRIPT_PATH" "log_info" "Has log_info function"
    assert_file_contains "$SCRIPT_PATH" "log_success" "Has log_success function"
    assert_file_contains "$SCRIPT_PATH" "log_warn" "Has log_warn function"
    assert_file_contains "$SCRIPT_PATH" "log_error" "Has log_error function"
}

# Test: Error handling for unknown preset
test_unknown_preset_handling() {
    assert_file_contains "$SCRIPT_PATH" "Unknown preset" "Handles unknown preset"
}

# Test: Project name handling
test_project_name_handling() {
    assert_file_contains "$SCRIPT_PATH" "PROJECT_NAME" "Uses PROJECT_NAME variable"
    assert_file_contains "$SCRIPT_PATH" "myproject" "Has default project name"
}

# Test: Build context validation
test_build_context_validation() {
    assert_file_contains "$SCRIPT_PATH" "BUILD_CONTEXT" "Uses BUILD_CONTEXT variable"
    assert_file_contains "$SCRIPT_PATH" "CONTAINERS_DIR" "References containers directory"
}

# Test: Dockerfile path validation
test_dockerfile_path_validation() {
    assert_file_contains "$SCRIPT_PATH" "DOCKERFILE" "Defines DOCKERFILE variable"
    assert_file_contains "$SCRIPT_PATH" "Dockerfile not found" "Validates Dockerfile exists"
}

# Test: Main function exists
test_main_function() {
    assert_file_contains "$SCRIPT_PATH" "main()" "Has main function"
    assert_file_contains "$SCRIPT_PATH" "main \"\$@\"" "Calls main with arguments"
}

# Test: Script can be sourced or executed
test_source_or_execute() {
    assert_file_contains "$SCRIPT_PATH" "BASH_SOURCE" "Checks if sourced or executed"
}

# Test: All presets disable dev tools
test_all_presets_disable_dev_tools() {
    # All production presets should disable dev tools
    # Check that each preset sets INCLUDE_DEV_TOOLS=false via base args
    assert_file_contains "$SCRIPT_PATH" "INCLUDE_DEV_TOOLS=false" "Dev tools disabled in base"
}

# Test: Version pinning in examples
test_version_pinning() {
    assert_file_contains "$SCRIPT_PATH" "PYTHON_VERSION=" "Python version configurable"
    assert_file_contains "$SCRIPT_PATH" "NODE_VERSION=" "Node version configurable"
}

# Run all tests
run_test test_script_exists "Script exists and is executable"
run_test test_shebang "Script has proper shebang"
run_test test_strict_mode "Script uses strict mode"
run_test test_help_available "Help text is available"
run_test test_presets_documented "Presets are documented"
run_test test_production_base_args "Production base args defined"
run_test test_minimal_preset_config "Minimal preset configured correctly"
run_test test_python_preset_config "Python preset configured correctly"
run_test test_node_preset_config "Node preset configured correctly"
run_test test_custom_preset "Custom preset available"
run_test test_argument_parsing "Argument parsing logic present"
run_test test_docker_command_construction "Docker command construction"
run_test test_image_tag_format "Image tag format correct"
run_test test_build_success_message "Build success message present"
run_test test_build_failure_handling "Build failure handled"
run_test test_next_steps "Next steps suggestions present"
run_test test_color_output "Color output support"
run_test test_logging_functions "Logging functions present"
run_test test_unknown_preset_handling "Unknown preset handling"
run_test test_project_name_handling "Project name handling"
run_test test_build_context_validation "Build context validation"
run_test test_dockerfile_path_validation "Dockerfile path validation"
run_test test_main_function "Main function exists"
run_test test_source_or_execute "Can be sourced or executed"
run_test test_all_presets_disable_dev_tools "All presets disable dev tools"
run_test test_version_pinning "Version pinning supported"

# Generate test report
generate_report
