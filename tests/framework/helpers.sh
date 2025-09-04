#!/usr/bin/env bash
# Test Helper Functions for Container Build Tests
# Version: 2.0.0
# Helper functions for container build testing
#
# Provides utility functions for test setup and execution.
# All helper variables use the tfh_ prefix to avoid namespace collisions.
#
# Key Features:
# - Command execution helpers with automatic assertions
# - Output capture utilities
# - Docker-specific test helpers
#
# Dependencies:
# - Test framework (framework.sh)
# - Docker installed and running
#
# Safety:
# - NO EVAL STATEMENTS - All functions use safe parameter expansion
# - Direct command execution using "$@"
# - Safe variable expansion throughout
#
# Usage:
#   Automatically loaded by framework.sh
#   Functions available in all test files

# Export variables for capture
export TEST_OUTPUT=""
export TEST_EXIT_CODE=0

# Capture command output and exit code
capture_result() {
    local tfh_output
    local tfh_exit_code
    
    # Execute command and capture output
    tfh_output=$("$@" 2>&1) || tfh_exit_code=$?
    
    # Export results
    TEST_OUTPUT="$tfh_output"
    TEST_EXIT_CODE="${tfh_exit_code:-0}"
    
    # Return original exit code
    return $TEST_EXIT_CODE
}

# Execute with warnings suppressed (useful for testing error conditions)
with_warnings_suppressed() {
    local tfh_old_log_level="${LOG_LEVEL:-}"
    export LOG_LEVEL=2  # ERROR level only
    
    # Execute command
    "$@"
    local tfh_exit_code=$?
    
    # Restore log level
    if [ -n "$tfh_old_log_level" ]; then
        export LOG_LEVEL="$tfh_old_log_level"
    else
        unset LOG_LEVEL
    fi
    
    return $tfh_exit_code
}

# Docker-specific helpers

# Build a test image and track it for cleanup
build_test_image() {
    local image_tag="$1"
    shift
    local build_args=("$@")
    
    # Build the image
    if docker build -t "$image_tag" "${build_args[@]}"; then
        # Track for cleanup
        TEST_IMAGES+=("$image_tag")
        return 0
    else
        return 1
    fi
}

# Run a container and track it for cleanup
run_test_container() {
    local container_name="$1"
    local image="$2"
    shift 2
    local run_args=("$@")
    
    # Run the container
    if docker run --name "$container_name" "$image" "${run_args[@]}"; then
        # Track for cleanup
        TEST_CONTAINERS+=("$container_name")
        return 0
    else
        return 1
    fi
}

# Execute command in a test container
exec_in_container() {
    local image="$1"
    local command="$2"
    
    docker run --rm "$image" bash -c "$command"
}

# Check if image exists
image_exists() {
    local image="$1"
    docker image inspect "$image" >/dev/null 2>&1
}

# Check if container is running
container_running() {
    local container="$1"
    docker ps --format '{{.Names}}' | grep -q "^${container}$"
}

# Get image size in MB
get_image_size_mb() {
    local image="$1"
    docker image inspect "$image" --format='{{.Size}}' | awk '{print int($1/1024/1024)}'
}

# Wait for container to be ready (with timeout)
wait_for_container() {
    local container="$1"
    local timeout="${2:-30}"
    local check_command="${3:-true}"
    
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        if docker exec "$container" bash -c "$check_command" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    
    return 1
}

# Export all helper functions
export -f capture_result
export -f with_warnings_suppressed
export -f build_test_image
export -f run_test_container
export -f exec_in_container
export -f image_exists
export -f container_running
export -f get_image_size_mb
export -f wait_for_container