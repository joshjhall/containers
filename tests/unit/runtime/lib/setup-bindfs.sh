#!/usr/bin/env bash
# Unit tests for lib/runtime/lib/setup-bindfs.sh

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Runtime Setup Bindfs Tests"

# Source file under test
SOURCE_FILE="$PROJECT_ROOT/lib/runtime/lib/setup-bindfs.sh"

# ============================================================================
# Static Analysis Tests
# ============================================================================

test_script_exists() {
    assert_file_exists "$SOURCE_FILE" "setup-bindfs.sh exists"
}

test_script_executable() {
    assert_executable "$SOURCE_FILE" "setup-bindfs.sh is executable"
}

test_defines_parse_bindfs_skip_paths() {
    assert_file_contains "$SOURCE_FILE" "parse_bindfs_skip_paths()" \
        "Defines parse_bindfs_skip_paths function"
}

test_defines_probe_mount_needs_fix() {
    assert_file_contains "$SOURCE_FILE" "probe_mount_needs_fix()" \
        "Defines probe_mount_needs_fix function"
}

test_defines_apply_bindfs_overlay() {
    assert_file_contains "$SOURCE_FILE" "apply_bindfs_overlay()" \
        "Defines apply_bindfs_overlay function"
}

test_defines_setup_bindfs_overlays() {
    assert_file_contains "$SOURCE_FILE" "setup_bindfs_overlays()" \
        "Defines setup_bindfs_overlays function"
}

test_bindfs_enabled_default() {
    assert_file_contains "$SOURCE_FILE" 'BINDFS_ENABLED="${BINDFS_ENABLED:-auto}"' \
        "BINDFS_ENABLED defaults to auto"
}

test_dev_fuse_check() {
    assert_file_contains "$SOURCE_FILE" "/dev/fuse" \
        "Script checks for /dev/fuse availability"
}

test_fuse_fstype_skip() {
    assert_file_contains "$SOURCE_FILE" '*fuse*' \
        "Script skips FUSE filesystem types"
}

test_virtiofs_detection() {
    assert_file_contains "$SOURCE_FILE" "virtiofs" \
        "Script detects virtiofs filesystem type"
}

test_grpcfuse_detection() {
    assert_file_contains "$SOURCE_FILE" "grpcfuse" \
        "Script detects grpcfuse filesystem type"
}

test_osxfs_detection() {
    assert_file_contains "$SOURCE_FILE" "osxfs" \
        "Script detects osxfs filesystem type"
}

test_fakeowner_detection() {
    assert_file_contains "$SOURCE_FILE" "fakeowner" \
        "Script detects fakeowner filesystem type"
}

test_skip_paths_comma_split() {
    assert_file_contains "$SOURCE_FILE" "IFS=',' read -ra" \
        "Script comma-splits BINDFS_SKIP_PATHS"
}

test_probe_file_pattern() {
    assert_file_contains "$SOURCE_FILE" ".bindfs-probe-" \
        "Script uses .bindfs-probe-PID pattern"
}

test_bindfs_force_user_option() {
    assert_file_contains "$SOURCE_FILE" "--force-user=" \
        "Script passes --force-user to bindfs"
}

test_bindfs_create_for_group_option() {
    assert_file_contains "$SOURCE_FILE" "--create-for-group=" \
        "Script passes --create-for-group to bindfs"
}

test_bindfs_allow_other_option() {
    assert_file_contains "$SOURCE_FILE" "-o allow_other" \
        "Script passes -o allow_other to bindfs"
}

test_fuse_hidden_cleanup() {
    assert_file_contains "$SOURCE_FILE" ".fuse_hidden" \
        "Script handles .fuse_hidden file cleanup"
}

test_fuser_check() {
    assert_file_contains "$SOURCE_FILE" "fuser" \
        "Script checks fuser before removing hidden files"
}

test_skip_map_associative_array() {
    assert_file_contains "$SOURCE_FILE" "BINDFS_SKIP_MAP" \
        "Script uses BINDFS_SKIP_MAP associative array"
}

test_dev_fuse_warning() {
    assert_file_contains "$SOURCE_FILE" "/dev/fuse not available" \
        "Script warns when /dev/fuse is not available"
}

test_applied_counter() {
    assert_file_contains "$SOURCE_FILE" "BINDFS_APPLIED" \
        "Script tracks count of applied overlays"
}

# ============================================================================
# Functional Tests
# ============================================================================

test_parse_skip_paths_sets_map() {
    (
        # Source the script to get the function
        source "$SOURCE_FILE"

        export BINDFS_SKIP_PATHS="/workspace/a,/workspace/b, /workspace/c "
        parse_bindfs_skip_paths

        # Check all three keys are set
        [ -n "${BINDFS_SKIP_MAP[/workspace/a]+_}" ] || exit 1
        [ -n "${BINDFS_SKIP_MAP[/workspace/b]+_}" ] || exit 1
        [ -n "${BINDFS_SKIP_MAP[/workspace/c]+_}" ] || exit 1
    )
    assert_equals "0" "$?" "parse_bindfs_skip_paths populates BINDFS_SKIP_MAP from env"
}

test_parse_skip_paths_empty() {
    (
        source "$SOURCE_FILE"

        unset BINDFS_SKIP_PATHS 2>/dev/null || true
        parse_bindfs_skip_paths

        # Map should be empty (0 keys)
        [ "${#BINDFS_SKIP_MAP[@]}" -eq 0 ] || exit 1
    )
    assert_equals "0" "$?" "parse_bindfs_skip_paths handles empty BINDFS_SKIP_PATHS"
}

test_parse_skip_paths_multiple_spaces() {
    (
        source "$SOURCE_FILE"

        export BINDFS_SKIP_PATHS="  /cache  ,   /tmp   "
        parse_bindfs_skip_paths

        [ -n "${BINDFS_SKIP_MAP[/cache]+_}" ] || exit 1
        [ -n "${BINDFS_SKIP_MAP[/tmp]+_}" ] || exit 1
        [ "${#BINDFS_SKIP_MAP[@]}" -eq 2 ] || exit 1
    )
    assert_equals "0" "$?" "parse_bindfs_skip_paths trims multiple leading/trailing spaces"
}

test_parse_skip_paths_tabs() {
    (
        source "$SOURCE_FILE"

        export BINDFS_SKIP_PATHS=$'\t/cache\t,\t/tmp'
        parse_bindfs_skip_paths

        [ -n "${BINDFS_SKIP_MAP[/cache]+_}" ] || exit 1
        [ -n "${BINDFS_SKIP_MAP[/tmp]+_}" ] || exit 1
        [ "${#BINDFS_SKIP_MAP[@]}" -eq 2 ] || exit 1
    )
    assert_equals "0" "$?" "parse_bindfs_skip_paths trims tab characters"
}

test_parse_skip_paths_mixed_whitespace() {
    (
        source "$SOURCE_FILE"

        export BINDFS_SKIP_PATHS=$' \t /cache \t , \t /var \t '
        parse_bindfs_skip_paths

        [ -n "${BINDFS_SKIP_MAP[/cache]+_}" ] || exit 1
        [ -n "${BINDFS_SKIP_MAP[/var]+_}" ] || exit 1
        [ "${#BINDFS_SKIP_MAP[@]}" -eq 2 ] || exit 1
    )
    assert_equals "0" "$?" "parse_bindfs_skip_paths trims mixed spaces and tabs"
}

test_parse_skip_paths_whitespace_only_fields() {
    (
        source "$SOURCE_FILE"

        export BINDFS_SKIP_PATHS=$'  , \t ,  '
        parse_bindfs_skip_paths

        [ "${#BINDFS_SKIP_MAP[@]}" -eq 0 ] || exit 1
    )
    assert_equals "0" "$?" "parse_bindfs_skip_paths ignores whitespace-only fields"
}

test_probe_fuse_fstype_skipped() {
    (
        source "$SOURCE_FILE"

        declare -gA BINDFS_SKIP_MAP=()
        # A fuse fstype should return 1 (skip)
        probe_mount_needs_fix "/workspace/test" "fuse.bindfs" "auto" >/dev/null 2>&1
    )
    assert_not_equals "0" "$?" "probe_mount_needs_fix returns 1 for fuse fstype"
}

test_probe_true_mode_always_applies() {
    (
        source "$SOURCE_FILE"

        declare -gA BINDFS_SKIP_MAP=()
        # In "true" mode with non-fuse fstype, should return 0 (apply)
        probe_mount_needs_fix "/workspace/test" "ext4" "true" >/dev/null 2>&1
    )
    assert_equals "0" "$?" "probe_mount_needs_fix returns 0 in true mode"
}

test_probe_skips_listed_path() {
    (
        source "$SOURCE_FILE"

        declare -gA BINDFS_SKIP_MAP=(["/workspace/skip"]=1)
        probe_mount_needs_fix "/workspace/skip" "ext4" "true" >/dev/null 2>&1
    )
    assert_not_equals "0" "$?" "probe_mount_needs_fix skips paths in BINDFS_SKIP_MAP"
}

# ============================================================================
# Run all tests
# ============================================================================

# Static analysis
run_test test_script_exists "Script exists"
run_test test_script_executable "Script is executable"
run_test test_defines_parse_bindfs_skip_paths "Defines parse_bindfs_skip_paths"
run_test test_defines_probe_mount_needs_fix "Defines probe_mount_needs_fix"
run_test test_defines_apply_bindfs_overlay "Defines apply_bindfs_overlay"
run_test test_defines_setup_bindfs_overlays "Defines setup_bindfs_overlays"
run_test test_bindfs_enabled_default "BINDFS_ENABLED defaults to auto"
run_test test_dev_fuse_check "Checks /dev/fuse availability"
run_test test_fuse_fstype_skip "Skips fuse filesystem types"
run_test test_virtiofs_detection "Detects virtiofs"
run_test test_grpcfuse_detection "Detects grpcfuse"
run_test test_osxfs_detection "Detects osxfs"
run_test test_fakeowner_detection "Detects fakeowner"
run_test test_skip_paths_comma_split "Comma-splits BINDFS_SKIP_PATHS"
run_test test_probe_file_pattern "Uses .bindfs-probe-PID pattern"
run_test test_bindfs_force_user_option "Passes --force-user to bindfs"
run_test test_bindfs_create_for_group_option "Passes --create-for-group to bindfs"
run_test test_bindfs_allow_other_option "Passes -o allow_other to bindfs"
run_test test_fuse_hidden_cleanup "Handles .fuse_hidden cleanup"
run_test test_fuser_check "Checks fuser before removing hidden files"
run_test test_skip_map_associative_array "Uses BINDFS_SKIP_MAP"
run_test test_dev_fuse_warning "Warns when /dev/fuse not available"
run_test test_applied_counter "Tracks applied overlay count"

# Functional tests
run_test test_parse_skip_paths_sets_map "parse_bindfs_skip_paths populates map"
run_test test_parse_skip_paths_empty "parse_bindfs_skip_paths handles empty input"
run_test test_probe_fuse_fstype_skipped "probe_mount_needs_fix skips fuse fstype"
run_test test_probe_true_mode_always_applies "probe_mount_needs_fix applies in true mode"
run_test test_probe_skips_listed_path "probe_mount_needs_fix skips listed paths"

# Generate test report
generate_report
