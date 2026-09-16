#!/usr/bin/env bash
# @tier: merge,weekly
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

# This suite builds and runs containers (#831).
require_docker

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

    assert_command_in_container "$image" "bindfs --version 2>&1 | command head -1" "bindfs"
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

# Test: fuse-cleanup-cron wrapper script exists and is executable
test_fuse_cleanup_cron_script() {
    local image="${IMAGE_TO_TEST:-test-bindfs-$$}"

    assert_command_in_container "$image" "test -x /usr/local/bin/fuse-cleanup-cron && echo exists" "exists"
}

# Test: fuse-cleanup cron job file exists with correct permissions
test_fuse_cleanup_cron_job() {
    local image="${IMAGE_TO_TEST:-test-bindfs-$$}"

    assert_command_in_container "$image" "test -f /etc/cron.d/fuse-cleanup && echo exists" "exists"
    # Verify permissions are 644 (rw-r--r--)
    assert_command_in_container "$image" "stat -c '%a' /etc/cron.d/fuse-cleanup" "644"
}

# Test: Cron daemon is installed (auto-triggered by bindfs)
test_cron_installed() {
    local image="${IMAGE_TO_TEST:-test-bindfs-$$}"

    assert_executable_in_path "$image" "cron"
}

# Test: shared fuse-cleanup GC is installed and executable (issue #948)
# Both the cron wrapper and the boot pass delegate to this script; if it is
# missing, both legs silently become no-ops.
test_fuse_cleanup_shared_script() {
    local image="${IMAGE_TO_TEST:-test-bindfs-$$}"

    assert_command_in_container "$image" "test -x /usr/local/bin/fuse-cleanup && echo exists" "exists"
}

# Test: shared GC exits cleanly and reports 0 with no FUSE mounts
test_fuse_cleanup_shared_script_runs() {
    local image="${IMAGE_TO_TEST:-test-bindfs-$$}"

    assert_command_in_container "$image" "/usr/local/bin/fuse-cleanup" "0"
}

# Test: fuse-cleanup-cron wrapper exits cleanly with no FUSE mounts
test_fuse_cleanup_cron_runs() {
    local image="${IMAGE_TO_TEST:-test-bindfs-$$}"

    assert_command_in_container "$image" "bash /usr/local/bin/fuse-cleanup-cron; echo exit_\$?" "exit_0"
}

# Test: a build without the bindfs flag excludes bindfs but STILL ships the
# shared fuse-cleanup GC (issue #954).
#
# The second half is the load-bearing one, and it is the half that was missing.
# The Dockerfile installs /usr/local/bin/fuse-cleanup unconditionally rather than
# behind INCLUDE_BINDFS, and that is deliberate: entrypoint.sh sources
# lib/runtime/lib/setup-bindfs.sh with no INCLUDE_BINDFS gate, so the boot pass
# calls the GC on EVERY image. Its missing-binary branch reports rather than
# skips, by design (#951) — so gating the install would trade ~10 KB for a
# permanent "FUSE cleanup skipped" warning at boot on every non-bindfs
# container. Until this test existed, a minimalism pass could add that gate and
# the whole suite would stay green.
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

    # ...but the shared GC the ungated boot pass calls MUST be.
    assert_command_in_container "$image" "test -x /usr/local/bin/fuse-cleanup && echo exists" "exists"

    # Presence is not enough: a truncated or non-executing copy would satisfy the
    # check above. Run it and pin its output (0 files cleaned, no FUSE mounts),
    # mirroring test_fuse_cleanup_shared_script_runs on the bindfs image.
    #
    # The comparison is done INSIDE the container rather than by handing "0" to
    # assert_command_in_container, because that helper matches its expected value
    # as a SUBSTRING (`[[ "$TEST_OUTPUT" == *"$expected"* ]]`, see
    # tests/framework/assertions/docker.sh). Against a bare "0" that is not an
    # assertion at all: a regressed sweep reporting 10, 20 or 100 stranded files
    # contains a "0" and would pass — the exact false-pass this assertion exists
    # to prevent. Emitting a distinct token on equality keeps the substring
    # semantics harmless.
    assert_command_in_container "$image" \
        '[ "$(/usr/local/bin/fuse-cleanup)" = "0" ] && echo cleaned-none' "cleaned-none"
}

# Run all tests
run_test test_bindfs_build "Bindfs builds successfully"
run_test test_bindfs_version "bindfs --version works"
run_test test_fuse_conf "/etc/fuse.conf has user_allow_other"
run_test test_entrypoint_has_bindfs "Entrypoint contains bindfs logic"
run_test test_fuse_cleanup_cron_script "fuse-cleanup-cron wrapper exists and is executable"
run_test test_fuse_cleanup_cron_job "fuse-cleanup cron job has correct permissions"
run_test test_cron_installed "Cron daemon auto-installed with bindfs"
run_test test_fuse_cleanup_shared_script "shared fuse-cleanup GC is installed"
run_test test_fuse_cleanup_shared_script_runs "shared fuse-cleanup GC runs cleanly"
run_test test_fuse_cleanup_cron_runs "fuse-cleanup-cron runs cleanly"
run_test test_no_bindfs_without_flag "Build without bindfs excludes it but keeps the shared GC"

# Generate test report
generate_report
