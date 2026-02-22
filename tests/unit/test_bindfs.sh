#!/usr/bin/env bash
# Unit tests for bindfs feature
#
# This test validates that:
# 1. Feature script exists and has correct structure
# 2. Installs bindfs and fuse3 packages
# 3. Configures fuse.conf with user_allow_other
# 4. Entrypoint contains bindfs overlay section
# 5. Dockerfile contains INCLUDE_BINDFS and INCLUDE_DEV_TOOLS trigger

set -euo pipefail

# Source test framework
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Bindfs Feature Tests"

# Setup
FEATURE_FILE="$PROJECT_ROOT/lib/features/bindfs.sh"
ENTRYPOINT_FILE="$PROJECT_ROOT/lib/runtime/entrypoint.sh"
DOCKERFILE="$PROJECT_ROOT/Dockerfile"

# Test: Feature script exists and is executable
test_feature_script_exists() {
    assert_file_exists "$FEATURE_FILE"
    assert_executable "$FEATURE_FILE"
}

# Test: Feature script sources correct headers
test_feature_script_headers() {
    assert_file_contains "$FEATURE_FILE" "feature-header.sh" "Sources feature-header.sh"
    assert_file_contains "$FEATURE_FILE" "apt-utils.sh" "Sources apt-utils.sh"
}

# Test: Feature script installs bindfs and fuse3 packages
test_installs_packages() {
    assert_file_contains "$FEATURE_FILE" "apt_install bindfs fuse3" "Installs bindfs and fuse3"
}

# Test: Feature script configures fuse.conf
test_configures_fuse_conf() {
    assert_file_contains "$FEATURE_FILE" "user_allow_other" "Configures user_allow_other in fuse.conf"
    assert_file_contains "$FEATURE_FILE" "/etc/fuse.conf" "References /etc/fuse.conf"
}

# Test: Feature script verifies bindfs installation
test_verifies_installation() {
    assert_file_contains "$FEATURE_FILE" "bindfs --version" "Verifies bindfs version"
    assert_file_contains "$FEATURE_FILE" "fusermount3" "Verifies fusermount3"
}

# Test: Feature script has log_feature_start/end
test_feature_logging() {
    assert_file_contains "$FEATURE_FILE" "log_feature_start" "Has log_feature_start"
    assert_file_contains "$FEATURE_FILE" "log_feature_end" "Has log_feature_end"
    assert_file_contains "$FEATURE_FILE" "log_feature_summary" "Has log_feature_summary"
}

# Test: Feature script creates fuse-cleanup-cron wrapper
test_creates_fuse_cleanup_cron_script() {
    assert_file_contains "$FEATURE_FILE" "/usr/local/bin/fuse-cleanup-cron" "Creates fuse-cleanup-cron wrapper script"
    assert_file_contains "$FEATURE_FILE" "FUSE_CLEANUP_DISABLE" "Respects FUSE_CLEANUP_DISABLE"
    assert_file_contains "$FEATURE_FILE" "findmnt.*fuse" "Uses findmnt to find FUSE mount points"
    assert_file_contains "$FEATURE_FILE" "fuser" "Uses fuser to check open files"
    assert_file_contains "$FEATURE_FILE" "logger -t fuse-cleanup" "Logs via syslog"
}

# Test: Feature script creates cron job file
test_creates_fuse_cleanup_cron_job() {
    assert_file_contains "$FEATURE_FILE" "/etc/cron.d/fuse-cleanup" "Creates cron job file"
    assert_file_contains "$FEATURE_FILE" "chmod 644 /etc/cron.d/fuse-cleanup" "Sets correct cron job permissions"
    # Verify 10-minute schedule
    assert_file_contains "$FEATURE_FILE" '*/10' "Cron job runs every 10 minutes"
}

# Test: Feature summary includes cron paths and env
test_feature_summary_includes_cron() {
    assert_file_contains "$FEATURE_FILE" "fuse-cleanup-cron" "Feature summary includes cron script path"
    assert_file_contains "$FEATURE_FILE" "FUSE_CLEANUP_DISABLE" "Feature summary includes FUSE_CLEANUP_DISABLE env var"
}

# Test: Entrypoint contains bindfs overlay section
test_entrypoint_has_bindfs_section() {
    assert_file_contains "$ENTRYPOINT_FILE" "Bindfs Overlay" "Entrypoint has Bindfs Overlay section header"
    assert_file_contains "$ENTRYPOINT_FILE" "BINDFS_ENABLED" "Entrypoint references BINDFS_ENABLED"
    assert_file_contains "$ENTRYPOINT_FILE" "BINDFS_SKIP_PATHS" "Entrypoint references BINDFS_SKIP_PATHS"
}

# Test: Entrypoint checks for bindfs binary
test_entrypoint_checks_bindfs_binary() {
    assert_file_contains "$ENTRYPOINT_FILE" "command -v bindfs" "Entrypoint checks for bindfs binary"
}

# Test: Entrypoint checks for /dev/fuse
test_entrypoint_checks_dev_fuse() {
    assert_file_contains "$ENTRYPOINT_FILE" "/dev/fuse" "Entrypoint checks for /dev/fuse"
}

# Test: Entrypoint uses findmnt to discover mounts (without --submounts)
test_entrypoint_uses_findmnt() {
    assert_file_contains "$ENTRYPOINT_FILE" "findmnt" "Entrypoint uses findmnt for mount discovery"
    # Must NOT use --submounts in the actual findmnt command
    # (fails when /workspace isn't itself a mount point)
    assert_file_not_contains "$ENTRYPOINT_FILE" "findmnt.*--submounts" \
        "Entrypoint does not use --submounts (breaks when /workspace is not a mount point)"
    # Must grep for /workspace prefix to filter mounts
    assert_file_contains "$ENTRYPOINT_FILE" "grep.*workspace" \
        "Entrypoint filters findmnt output by /workspace prefix"
}

# Test: Entrypoint applies bindfs with correct options
test_entrypoint_bindfs_options() {
    assert_file_contains "$ENTRYPOINT_FILE" "force-user" "Entrypoint uses --force-user"
    assert_file_contains "$ENTRYPOINT_FILE" "force-group" "Entrypoint uses --force-group"
    assert_file_contains "$ENTRYPOINT_FILE" "allow_other" "Entrypoint uses allow_other"
    assert_file_contains "$ENTRYPOINT_FILE" "create-for-user" "Entrypoint uses --create-for-user"
    assert_file_contains "$ENTRYPOINT_FILE" "create-for-group" "Entrypoint uses --create-for-group"
}

# Test: Entrypoint supports auto/true/false modes
test_entrypoint_bindfs_modes() {
    assert_file_contains "$ENTRYPOINT_FILE" '"auto"' "Entrypoint supports auto mode"
    assert_file_contains "$ENTRYPOINT_FILE" '"false"' "Entrypoint supports false mode"
    assert_file_contains "$ENTRYPOINT_FILE" '"true"' "Entrypoint supports true mode"
}

# Test: Entrypoint probes permissions in auto mode
test_entrypoint_permission_probe() {
    assert_file_contains "$ENTRYPOINT_FILE" "chmod 755" "Entrypoint probes with chmod 755"
    assert_file_contains "$ENTRYPOINT_FILE" "bindfs-probe" "Entrypoint creates probe file"
}

# Test: Entrypoint detects Docker Desktop filesystem types that fake permissions
test_entrypoint_detects_fake_fs_types() {
    assert_file_contains "$ENTRYPOINT_FILE" "fakeowner" \
        "Entrypoint detects fakeowner filesystem (Docker Desktop FUSE layer)"
    assert_file_contains "$ENTRYPOINT_FILE" "virtiofs" \
        "Entrypoint detects virtiofs filesystem (Docker Desktop 4.x+)"
    assert_file_contains "$ENTRYPOINT_FILE" "grpcfuse" \
        "Entrypoint detects grpcfuse filesystem (older Docker Desktop)"
    assert_file_contains "$ENTRYPOINT_FILE" "osxfs" \
        "Entrypoint detects osxfs filesystem (legacy macOS sharing)"
}

# Test: Entrypoint skips fuse mounts
test_entrypoint_skips_fuse() {
    assert_file_contains "$ENTRYPOINT_FILE" "fuse" "Entrypoint checks for fuse fstype"
}

# Test: Entrypoint uses existing privilege escalation pattern
test_entrypoint_privilege_pattern() {
    assert_file_contains "$ENTRYPOINT_FILE" "RUNNING_AS_ROOT" "Entrypoint uses RUNNING_AS_ROOT variable"
    assert_file_contains "$ENTRYPOINT_FILE" "bindfs_run_privileged" "Entrypoint has bindfs privilege helper"
}

# Test: Dockerfile contains INCLUDE_BINDFS build arg
test_dockerfile_build_arg() {
    assert_file_contains "$DOCKERFILE" "ARG INCLUDE_BINDFS=false" "Dockerfile declares INCLUDE_BINDFS arg"
}

# Test: Dockerfile triggers bindfs from INCLUDE_DEV_TOOLS
test_dockerfile_dev_tools_trigger() {
    # The bindfs conditional line checks both INCLUDE_BINDFS and INCLUDE_DEV_TOOLS:
    #   if [ "${INCLUDE_BINDFS}" = "true" ] || [ "${INCLUDE_DEV_TOOLS}" = "true" ]; then
    assert_file_contains "$DOCKERFILE" 'INCLUDE_BINDFS.*INCLUDE_DEV_TOOLS' \
        "Dockerfile bindfs block checks both INCLUDE_BINDFS and INCLUDE_DEV_TOOLS"
}

# Test: Dockerfile triggers cron from INCLUDE_BINDFS
test_dockerfile_cron_bindfs_trigger() {
    # The cron conditional should include INCLUDE_BINDFS in the condition that runs cron.sh
    # Extract the cron RUN block and verify INCLUDE_BINDFS is in its condition
    local cron_block
    cron_block=$(sed -n '/INCLUDE_CRON/,/cron\.sh/p' "$DOCKERFILE")
    assert_true echo "$cron_block" | grep -q 'INCLUDE_BINDFS' \
        "Dockerfile cron auto-trigger condition includes INCLUDE_BINDFS"
}

# Test: Dockerfile runs bindfs.sh
test_dockerfile_runs_bindfs_script() {
    assert_file_contains "$DOCKERFILE" "bindfs.sh" "Dockerfile runs bindfs.sh"
}

# Test: Entrypoint FUSE cleanup references cron job for ongoing cleanup
test_entrypoint_fuse_cleanup_mentions_cron() {
    assert_file_contains "$ENTRYPOINT_FILE" "boot-time" \
        "Entrypoint FUSE cleanup section mentions boot-time"
    assert_file_contains "$ENTRYPOINT_FILE" "fuse-cleanup-cron" \
        "Entrypoint FUSE cleanup section references cron job"
}

# Test: Bindfs section is between cache fix and cron in entrypoint
test_entrypoint_section_ordering() {
    # Get line numbers to verify ordering
    local cache_line entrypoint_bindfs_line cron_line
    cache_line=$(grep -n "Cache Directory Permissions Fix" "$ENTRYPOINT_FILE" | head -1 | cut -d: -f1)
    entrypoint_bindfs_line=$(grep -n "Bindfs Overlay" "$ENTRYPOINT_FILE" | head -1 | cut -d: -f1)
    cron_line=$(grep -n "Cron Daemon Startup" "$ENTRYPOINT_FILE" | head -1 | cut -d: -f1)

    assert_true [ "$cache_line" -lt "$entrypoint_bindfs_line" ] "Bindfs section comes after cache fix"
    assert_true [ "$entrypoint_bindfs_line" -lt "$cron_line" ] "Bindfs section comes before cron startup"
}

# Run all tests
run_test test_feature_script_exists "Feature script exists and is executable"
run_test test_feature_script_headers "Feature script sources correct headers"
run_test test_installs_packages "Feature script installs bindfs and fuse3"
run_test test_configures_fuse_conf "Feature script configures fuse.conf"
run_test test_verifies_installation "Feature script verifies installation"
run_test test_feature_logging "Feature script has proper logging"
run_test test_entrypoint_has_bindfs_section "Entrypoint has bindfs overlay section"
run_test test_entrypoint_checks_bindfs_binary "Entrypoint checks for bindfs binary"
run_test test_entrypoint_checks_dev_fuse "Entrypoint checks for /dev/fuse"
run_test test_entrypoint_uses_findmnt "Entrypoint uses findmnt for mount discovery"
run_test test_entrypoint_bindfs_options "Entrypoint applies bindfs with correct options"
run_test test_entrypoint_bindfs_modes "Entrypoint supports all BINDFS_ENABLED modes"
run_test test_entrypoint_permission_probe "Entrypoint probes permissions in auto mode"
run_test test_entrypoint_detects_fake_fs_types "Entrypoint detects Docker Desktop fake filesystem types"
run_test test_entrypoint_skips_fuse "Entrypoint skips existing fuse mounts"
run_test test_entrypoint_privilege_pattern "Entrypoint uses existing privilege pattern"
run_test test_creates_fuse_cleanup_cron_script "Feature script creates fuse-cleanup-cron wrapper"
run_test test_creates_fuse_cleanup_cron_job "Feature script creates fuse-cleanup cron job"
run_test test_feature_summary_includes_cron "Feature summary includes cron paths and env"
run_test test_dockerfile_build_arg "Dockerfile declares INCLUDE_BINDFS build arg"
run_test test_dockerfile_dev_tools_trigger "Dockerfile triggers bindfs from INCLUDE_DEV_TOOLS"
run_test test_dockerfile_cron_bindfs_trigger "Dockerfile triggers cron from INCLUDE_BINDFS"
run_test test_dockerfile_runs_bindfs_script "Dockerfile runs bindfs.sh"
run_test test_entrypoint_fuse_cleanup_mentions_cron "Entrypoint FUSE cleanup references cron job"
run_test test_entrypoint_section_ordering "Bindfs section is correctly ordered in entrypoint"

# Generate test report
generate_report
