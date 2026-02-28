#!/usr/bin/env bash
# Docker-specific assertions for container testing
# Version: 1.0.0
#
# Provides Docker-specific assertion functions for testing container builds.
# All assertion functions follow the pattern: assert_* for positive assertions
#
# Dependencies:
# - Test framework core (framework.sh)
# - Docker installed and running
#
# Usage:
#   Automatically loaded by framework.sh
#   Use these assertions in your test functions

# Assert that a Docker image exists
assert_image_exists() {
    local image="$1"
    local message="${2:-Image $image should exist}"

    if docker image inspect "$image" >/dev/null 2>&1; then
        return 0
    else
        tf_fail_assertion "$message" \
            "Image not found: $image"
    fi
}

# Assert that a Docker image does not exist
assert_image_not_exists() {
    local image="$1"
    local message="${2:-Image $image should not exist}"

    if ! docker image inspect "$image" >/dev/null 2>&1; then
        return 0
    else
        tf_fail_assertion "$message" \
            "Image exists: $image"
    fi
}

# Assert that a container is running
assert_container_running() {
    local container="$1"
    local message="${2:-Container $container should be running}"

    if docker ps --format '{{.Names}}' | command grep -q "^${container}$"; then
        return 0
    else
        tf_fail_assertion "$message" \
            "Container not running: $container"
    fi
}

# Assert that a container is not running
assert_container_not_running() {
    local container="$1"
    local message="${2:-Container $container should not be running}"

    if ! docker ps --format '{{.Names}}' | command grep -q "^${container}$"; then
        return 0
    else
        tf_fail_assertion "$message" \
            "Container is running: $container"
    fi
}

# Assert that a build succeeds
assert_build_succeeds() {
    local dockerfile="$1"
    shift
    local build_args=("$@")
    local build_context="${BUILD_CONTEXT:-.}"

    capture_result docker build -f "$dockerfile" "${build_args[@]}" "$build_context"
    if [ "$TEST_EXIT_CODE" -eq 0 ]; then
        return 0
    else
        tf_fail_assertion "Build should succeed" \
            "Exit code: $TEST_EXIT_CODE" \
            "Output: $TEST_OUTPUT"
    fi
}

# Assert that a build fails
assert_build_fails() {
    local dockerfile="$1"
    shift
    local build_args=("$@")

    capture_result docker build -f "$dockerfile" "${build_args[@]}" .
    if [ "$TEST_EXIT_CODE" -ne 0 ]; then
        return 0
    else
        tf_fail_assertion "Build should fail" \
            "Build succeeded unexpectedly"
    fi
}

# Assert that a command succeeds in a container
assert_command_in_container() {
    local image="$1"
    local command="$2"
    local expected="${3:-}"
    local message="${4:-Command should succeed in container}"

    capture_result docker run --rm "$image" bash -c "$command"

    if [ "$TEST_EXIT_CODE" -ne 0 ]; then
        tf_fail_assertion "$message" \
            "Command failed: $command" \
            "Exit code: $TEST_EXIT_CODE" \
            "Output: $TEST_OUTPUT"
        return 1
    fi

    if [ -n "$expected" ]; then
        if [[ "$TEST_OUTPUT" == *"$expected"* ]]; then
            return 0
        else
            tf_fail_assertion "$message" \
                "Expected output to contain: $expected" \
                "Actual output: $TEST_OUTPUT"
        fi
    fi
}

# Assert that a command fails in a container
assert_command_fails_in_container() {
    local image="$1"
    local command="$2"
    local message="${3:-Command should fail in container}"

    capture_result docker run --rm "$image" bash -c "$command"

    if [ "$TEST_EXIT_CODE" -eq 0 ]; then
        tf_fail_assertion "$message" \
            "Command succeeded unexpectedly: $command" \
            "Output: $TEST_OUTPUT"
    fi
}

# Assert image size is less than specified MB
assert_image_size_less_than() {
    local image="$1"
    local max_size_mb="$2"
    local message="${3:-Image size should be less than ${max_size_mb}MB}"

    local actual_size
    actual_size=$(get_image_size_mb "$image")

    if [ "$actual_size" -lt "$max_size_mb" ]; then
        return 0
    else
        tf_fail_assertion "$message" \
            "Expected: < ${max_size_mb}MB" \
            "Actual: ${actual_size}MB"
    fi
}

# Assert that a file exists in the image
assert_file_in_image() {
    local image="$1"
    local file_path="$2"
    local message="${3:-File $file_path should exist in image}"

    if docker run --rm "$image" test -f "$file_path"; then
        return 0
    else
        tf_fail_assertion "$message" \
            "File not found in image: $file_path"
    fi
}

# Assert that a directory exists in the image
assert_dir_in_image() {
    local image="$1"
    local dir_path="$2"
    local message="${3:-Directory $dir_path should exist in image}"

    if docker run --rm "$image" test -d "$dir_path"; then
        return 0
    else
        tf_fail_assertion "$message" \
            "Directory not found in image: $dir_path"
    fi
}

# Assert that an executable exists and is in PATH
assert_executable_in_path() {
    local image="$1"
    local executable="$2"
    local message="${3:-Executable $executable should be in PATH}"

    if docker run --rm "$image" which "$executable" >/dev/null 2>&1; then
        return 0
    else
        tf_fail_assertion "$message" \
            "Executable not found in PATH: $executable"
    fi
}

# Assert environment variable is set in image
assert_env_var_set() {
    local image="$1"
    local var_name="$2"
    local expected_value="${3:-}"
    local message="${4:-Environment variable $var_name should be set}"

    capture_result docker run --rm "$image" printenv "$var_name"

    if [ "$TEST_EXIT_CODE" -ne 0 ]; then
        tf_fail_assertion "$message" \
            "Variable not set: $var_name"
        return 1
    fi

    if [ -n "$expected_value" ]; then
        if [ "$TEST_OUTPUT" = "$expected_value" ]; then
            return 0
        else
            tf_fail_assertion "$message" \
                "Expected value: $expected_value" \
                "Actual value: $TEST_OUTPUT"
        fi
    fi
}

# Export all Docker assertion functions
export -f assert_image_exists
export -f assert_image_not_exists
export -f assert_container_running
export -f assert_container_not_running
export -f assert_build_succeeds
export -f assert_build_fails
export -f assert_command_in_container
export -f assert_command_fails_in_container
export -f assert_image_size_less_than
export -f assert_file_in_image
export -f assert_dir_in_image
export -f assert_executable_in_path
export -f assert_env_var_set
