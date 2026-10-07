#!/usr/bin/env bash
# @tier: weekly
# @ci: scheduled — needs its own INCLUDE_NODE (non-dev) build; no merge-tier variant matches (#1027)
# Test the node feature on a Node.js major that no longer bundles corepack
#
# Node.js 25+ release tarballs ship only node, npm, and npx. node.sh used to
# call corepack unconditionally, so NODE_VERSION=26 failed the build with
# exit 127 (#983). This builds that exact configuration and checks that
# corepack was provisioned and still activates yarn and pnpm.

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the test framework
source "$SCRIPT_DIR/../../framework.sh"

# Initialize the test framework
init_test_framework

# This suite builds and runs containers (#831).
require_docker

# For standalone testing, we build from containers directory
export BUILD_CONTEXT="$CONTAINERS_DIR"

# First Node.js major without a bundled corepack is 25; 26 is the one #983
# reported. Override to exercise a newer major.
NODE_CURRENT_VERSION="${NODE_CURRENT_VERSION:-26}"

# Define test suite
test_suite "Node ${NODE_CURRENT_VERSION} (no bundled corepack) Build"

# Test: node feature builds on a corepack-less Node.js
test_node_current_build() {
    if [ -n "${IMAGE_TO_TEST:-}" ]; then
        local image="$IMAGE_TO_TEST"
    else
        local image="test-node-current-$$"
        assert_build_succeeds "Dockerfile" \
            --build-arg PROJECT_PATH=. \
            --build-arg PROJECT_NAME=test-node-current \
            --build-arg INCLUDE_NODE=true \
            --build-arg NODE_VERSION="${NODE_CURRENT_VERSION}" \
            -t "$image"
    fi

    assert_command_in_container "$image" "node --version" "v${NODE_CURRENT_VERSION}."
    # Node 26's arm64 binary links libatomic.so.1 and exits 127 without it.
    # Check the package directly so an amd64 runner, whose node doesn't need
    # the library, still catches it being dropped from node.sh.
    assert_command_in_container "$image" "dpkg-query -W -f='\${Status}' libatomic1" "install ok installed"
}

# Test: corepack was installed and its shims resolve
test_node_current_corepack() {
    local image="${IMAGE_TO_TEST:-test-node-current-$$}"

    assert_executable_in_path "$image" "corepack"
    assert_executable_in_path "$image" "yarn"
    assert_executable_in_path "$image" "pnpm"
}

# Test: yarn and pnpm actually run through the installed corepack
test_node_current_package_managers() {
    local image="${IMAGE_TO_TEST:-test-node-current-$$}"

    # Exit status is the check: without corepack these are not on PATH at all.
    # The runtime user's corepack home differs from the build's (root), so the
    # pnpm@9 prepared at build time is not what resolves here; don't pin it.
    # First use downloads the release, so this needs registry access.
    assert_command_in_container "$image" "yarn --version" ""
    assert_command_in_container "$image" "pnpm --version" ""
}

# Run all tests
run_test test_node_current_build "Node ${NODE_CURRENT_VERSION} builds without a bundled corepack"
run_test test_node_current_corepack "corepack, yarn, and pnpm are on PATH"
run_test test_node_current_package_managers "yarn and pnpm run via the installed corepack"

# Generate test report
generate_report
