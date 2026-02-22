#!/usr/bin/env bash
# Test bindfs container build
#
# This test verifies that the bindfs feature:
# - Builds successfully with INCLUDE_BINDFS=true
# - Installs bindfs and fusermount3
# - Configures /etc/fuse.conf with user_allow_other
# - Does NOT include bindfs when the flag is not set

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the test framework
source "$SCRIPT_DIR/../../framework.sh"

# Initialize the test framework
init_test_framework

# For standalone testing, we build from containers directory
export BUILD_CONTEXT="$CONTAINERS_DIR"

# Define test suite
test_suite "Bindfs Container Build"

# Test: Bindfs builds successfully
test_bindfs_build() {
    # Use pre-built image if provided, otherwise build locally
    if [ -n "${IMAGE_TO_TEST:-}" ]; then
        local image="$IMAGE_TO_TEST"
        echo "Testing pre-built image: $image"
    else
        local image="test-bindfs-$$"
        echo "Building image locally: $image"

        # Build with bindfs enabled (standalone)
        assert_build_succeeds "Dockerfile" \
            --build-arg PROJECT_PATH=. \
            --build-arg PROJECT_NAME=test-bindfs \
            --build-arg INCLUDE_BINDFS=true \
            -t "$image"
    fi

    # Verify bindfs is installed
    assert_executable_in_path "$image" "bindfs"
    assert_executable_in_path "$image" "fusermount3"
}

# Test: bindfs --version works
test_bindfs_version() {
    local image="${IMAGE_TO_TEST:-test-bindfs-$$}"

    assert_command_in_container "$image" "bindfs --version 2>&1 | head -1" "bindfs"
}

# Test: /etc/fuse.conf has user_allow_other
test_fuse_conf() {
    local image="${IMAGE_TO_TEST:-test-bindfs-$$}"

    assert_command_in_container "$image" "grep -c user_allow_other /etc/fuse.conf" "1"
}

# Test: Entrypoint contains bindfs logic
test_entrypoint_has_bindfs() {
    local image="${IMAGE_TO_TEST:-test-bindfs-$$}"

    assert_command_in_container "$image" "grep -c BINDFS_ENABLED /usr/local/bin/entrypoint" ""
}

# Test: Build without bindfs flag does not include it
test_no_bindfs_without_flag() {
    local image="test-no-bindfs-$$"
    echo "Building image without bindfs: $image"

    # Build minimal container without bindfs
    assert_build_succeeds "Dockerfile" \
        --build-arg PROJECT_PATH=. \
        --build-arg PROJECT_NAME=test-no-bindfs \
        -t "$image"

    # bindfs should NOT be available
    assert_command_in_container "$image" "which bindfs 2>/dev/null || echo not-found" "not-found"
}

# Run all tests
run_test test_bindfs_build "Bindfs builds successfully"
run_test test_bindfs_version "bindfs --version works"
run_test test_fuse_conf "/etc/fuse.conf has user_allow_other"
run_test test_entrypoint_has_bindfs "Entrypoint contains bindfs logic"
run_test test_no_bindfs_without_flag "Build without bindfs flag excludes it"

# Generate test report
generate_report
