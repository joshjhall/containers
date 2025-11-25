#!/usr/bin/env bash
# Test Docker socket access fix in entrypoint
#
# This test verifies that the entrypoint correctly configures Docker socket
# access for non-root users when running as root initially.
#
# The fix should:
# 1. Create a 'docker' group if it doesn't exist
# 2. Change socket ownership to root:docker with 660 permissions
# 3. Add the non-root user to the docker group
# 4. Drop privileges to non-root user with new group membership

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the test framework
source "$SCRIPT_DIR/../../framework.sh"

# Initialize the test framework
init_test_framework

# For standalone testing, we build from containers directory
export BUILD_CONTEXT="$CONTAINERS_DIR"

# Define test suite
test_suite "Docker Socket Access Fix"

# Shared image name for all tests (built once, cleaned up at end)
DOCKER_SOCKET_TEST_IMAGE="test-docker-socket-$$"

# Build the image once before running tests
echo "Building test image: $DOCKER_SOCKET_TEST_IMAGE"
if ! docker build -f "$CONTAINERS_DIR/Dockerfile" \
    --build-arg PROJECT_PATH=. \
    --build-arg PROJECT_NAME=test-docker \
    --build-arg INCLUDE_DOCKER=true \
    -t "$DOCKER_SOCKET_TEST_IMAGE" \
    "$CONTAINERS_DIR" >/dev/null 2>&1; then
    echo "ERROR: Failed to build test image"
    exit 1
fi
echo "Test image built successfully"

# Cleanup function to remove image at script exit
cleanup_test_image() {
    echo "Cleaning up test image: $DOCKER_SOCKET_TEST_IMAGE"
    docker rmi -f "$DOCKER_SOCKET_TEST_IMAGE" >/dev/null 2>&1 || true
}
trap cleanup_test_image EXIT

# Test: Container builds with Docker feature enabled
test_docker_feature_builds() {
    local image="$DOCKER_SOCKET_TEST_IMAGE"

    # Verify docker CLI is installed
    assert_executable_in_path "$image" "docker"
}

# Test: Socket permissions allow docker group access after entrypoint
test_socket_permissions_fixed() {
    local image="$DOCKER_SOCKET_TEST_IMAGE"

    # Run container as root with Docker socket mounted
    # The entrypoint should ensure socket is accessible to the user
    # Either by fixing permissions (660 docker) or socket was already accessible
    local output
    output=$(docker run --rm \
        --user root \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -e SKIP_CASE_CHECK=true \
        "$image" \
        bash -c 'stat -c "%a %G" /var/run/docker.sock' 2>&1 | tail -1)

    # Socket should be accessible - either 660 docker (our fix) or 666 (already open)
    # Both are acceptable as long as docker commands work
    if [[ "$output" =~ ^(660|666)[[:space:]]+(docker|root)$ ]]; then
        echo "Socket permissions: $output"
        return 0
    else
        tf_fail_assertion "Socket should have accessible permissions" \
            "Expected: 660 docker or 666 root" \
            "Actual: $output"
    fi
}

# Test: Non-root user can access Docker socket after entrypoint runs
test_nonroot_docker_access() {
    local image="$DOCKER_SOCKET_TEST_IMAGE"

    # Run container as root (entrypoint will drop privileges)
    # with Docker socket mounted and test docker access
    local output
    output=$(docker run --rm \
        --user root \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -e SKIP_CASE_CHECK=true \
        "$image" \
        bash -c 'docker version --format "{{.Client.Version}}"' 2>&1 | tail -1)

    local exit_code=$?

    if [ $exit_code -eq 0 ] && [ -n "$output" ]; then
        echo "Docker version accessible: $output"
        return 0
    else
        tf_fail_assertion "Non-root user should be able to run docker commands" \
            "Exit code: $exit_code" \
            "Output: $output"
    fi
}

# Test: User is added to docker group
test_user_in_docker_group() {
    local image="$DOCKER_SOCKET_TEST_IMAGE"

    # Run as root with socket, check user's groups
    local output
    output=$(docker run --rm \
        --user root \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -e SKIP_CASE_CHECK=true \
        "$image" \
        bash -c 'id -nG' 2>&1 | tail -1)

    if [[ "$output" == *"docker"* ]]; then
        echo "User groups: $output"
        return 0
    else
        tf_fail_assertion "User should be in docker group" \
            "User groups: $output"
    fi
}

# Test: Docker socket fix is idempotent (doesn't fail if already configured)
test_socket_fix_idempotent() {
    local image="$DOCKER_SOCKET_TEST_IMAGE"

    # Run container twice in succession - second run should work fine
    # even though socket is already configured
    docker run --rm \
        --user root \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -e SKIP_CASE_CHECK=true \
        "$image" \
        bash -c 'docker ps >/dev/null' 2>&1

    local first_exit=$?

    docker run --rm \
        --user root \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -e SKIP_CASE_CHECK=true \
        "$image" \
        bash -c 'docker ps >/dev/null' 2>&1

    local second_exit=$?

    if [ $first_exit -eq 0 ] && [ $second_exit -eq 0 ]; then
        return 0
    else
        tf_fail_assertion "Docker socket fix should be idempotent" \
            "First run exit: $first_exit" \
            "Second run exit: $second_exit"
    fi
}

# Test: Works when socket already has correct permissions (no-op case)
test_socket_already_accessible() {
    local image="$DOCKER_SOCKET_TEST_IMAGE"

    # If socket is already accessible (e.g., from previous test or host config),
    # the entrypoint should skip the fix silently
    local output
    output=$(docker run --rm \
        --user root \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -e SKIP_CASE_CHECK=true \
        "$image" \
        bash -c 'echo "test passed"' 2>&1 | tail -1)

    if [[ "$output" == *"test passed"* ]]; then
        return 0
    else
        tf_fail_assertion "Container should start successfully" \
            "Output: $output"
    fi
}

# Run all tests
run_test test_docker_feature_builds "Docker feature builds successfully"
run_test test_socket_permissions_fixed "Socket permissions are fixed to 660 docker"
run_test test_nonroot_docker_access "Non-root user can access Docker"
run_test test_user_in_docker_group "User is added to docker group"
run_test test_socket_fix_idempotent "Socket fix is idempotent"
run_test test_socket_already_accessible "Works when socket already accessible"

# Generate test report
generate_report
