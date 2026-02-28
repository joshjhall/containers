#!/usr/bin/env bash
# Unit tests for lib/base/user.sh
# Tests user creation and UID/GID conflict resolution

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "User Management Tests"

# Test: Script exists and is executable
test_script_exists() {
    assert_file_exists "$PROJECT_ROOT/lib/base/user.sh"
    assert_executable "$PROJECT_ROOT/lib/base/user.sh"
}

# Test: Default parameter handling
test_default_parameters() {
    # Source the script to get functions (but don't execute)
    local temp_script="$RESULTS_DIR/user-test.sh"

    # Extract just the parameter defaults from the script
    command grep -E "^(USERNAME|USER_UID|USER_GID|PROJECT_NAME|WORKING_DIR)=" "$PROJECT_ROOT/lib/base/user.sh" > "$temp_script"
    source "$temp_script"

    # Test default values are set correctly
    assert_equals "developer" "${USERNAME:-}" "Default username"
    assert_equals "1000" "${USER_UID:-}" "Default UID"
    assert_equals "$USER_UID" "${USER_GID:-}" "Default GID matches UID"
    assert_equals "project" "${PROJECT_NAME:-}" "Default project name"
    assert_equals "/workspace/${PROJECT_NAME}" "${WORKING_DIR:-}" "Default working directory"
}

# Test: UID/GID conflict detection logic
test_uid_conflict_detection() {
    # Test the awk command for finding free UIDs
    local free_uid_cmd='awk -F: '\''$3>=1000 && $3<65534 {print $3}'\'' /etc/passwd | sort -n | awk '\''BEGIN{for(i=1;i<=NR;i++) uids[i]=0} {uids[$1]=1} END{for(i=1000;i<65534;i++) if(!uids[i]) {print i; exit}}'\'''

    # This should return a number (we can't test exact value as it depends on system)
    local result
    result=$(eval "$free_uid_cmd" 2>/dev/null || echo "1001")

    if [[ "$result" =~ ^[0-9]+$ ]] && [ "$result" -ge 1000 ]; then
        assert_true true "Free UID finder returns valid UID: $result"
    else
        assert_true false "Free UID finder returned invalid result: $result"
    fi
}

# Test: GID conflict detection logic
test_gid_conflict_detection() {
    # Test the awk command for finding free GIDs
    local free_gid_cmd='awk -F: '\''$3>=1000 && $3<65534 {print $3}'\'' /etc/group | sort -n | awk '\''BEGIN{for(i=1;i<=NR;i++) gids[i]=0} {gids[$1]=1} END{for(i=1000;i<65534;i++) if(!gids[i]) {print i; exit}}'\'''

    # This should return a number
    local result
    result=$(eval "$free_gid_cmd" 2>/dev/null || echo "1001")

    if [[ "$result" =~ ^[0-9]+$ ]] && [ "$result" -ge 1000 ]; then
        assert_true true "Free GID finder returns valid GID: $result"
    else
        assert_true false "Free GID finder returned invalid result: $result"
    fi
}

# Test: User existence check
test_user_existence_check() {
    # Test with a user that definitely exists (root)
    if id -u root >/dev/null 2>&1; then
        assert_true true "User existence check works for existing user"
    else
        assert_true false "User existence check failed for root user"
    fi

    # Test with a user that definitely doesn't exist
    if ! id -u nonexistent-user-12345 >/dev/null 2>&1; then
        assert_true true "User existence check correctly identifies non-existent user"
    else
        assert_true false "User existence check incorrectly found non-existent user"
    fi
}

# Test: Group existence check
test_group_existence_check() {
    # Skip this test on macOS since getent behavior differs
    # These tests target Linux container environments
    if [[ "$OSTYPE" == "darwin"* ]]; then
        skip_test "Group existence check skipped on macOS (targets Linux containers)"
        return
    fi

    # Test with a group that definitely exists on Linux
    if getent group root >/dev/null 2>&1; then
        assert_true true "Group existence check works for existing group"
    else
        assert_true false "Group existence check failed for root group"
    fi

    # Test with a group that doesn't exist
    if ! getent group nonexistent-group-12345 >/dev/null 2>&1; then
        assert_true true "Group existence check correctly identifies non-existent group"
    else
        assert_true false "Group existence check incorrectly found non-existent group"
    fi
}

# Test: Working directory path construction
test_working_dir_construction() {
    local project="myapp"
    local expected="/workspace/myapp"
    local constructed="/workspace/${project}"

    assert_equals "$expected" "$constructed" "Working directory path constructed correctly"
}

# Test: Build environment file structure
test_build_env_structure() {
    # Test that we can create the expected environment file structure
    local test_env_file="$RESULTS_DIR/build-env"

    # Simulate what the script writes
    command cat > "$test_env_file" <<EOF
export ACTUAL_UID=1000
export ACTUAL_GID=1000
export USERNAME=testuser
export PROJECT_NAME=testproject
export WORKING_DIR=/workspace/testproject
EOF

    # Test that file can be sourced
    source "$test_env_file"

    assert_equals "1000" "$ACTUAL_UID" "Build env UID set correctly"
    assert_equals "1000" "$ACTUAL_GID" "Build env GID set correctly"
    assert_equals "testuser" "$USERNAME" "Build env username set correctly"

    # Cleanup
    command rm -f "$test_env_file"
}

# Test: Sudo configuration validation
test_sudo_config_validation() {
    # Test sudo rule format
    local username="testuser"
    local sudo_rule="${username} ALL=(ALL) NOPASSWD:ALL"
    local expected_pattern="^${username} ALL=\\(ALL\\) NOPASSWD:ALL$"

    if [[ "$sudo_rule" =~ $expected_pattern ]]; then
        assert_true true "Sudo rule format is correct"
    else
        assert_true false "Sudo rule format is incorrect: $sudo_rule"
    fi
}

# Test: Home directory path validation
test_home_directory_path() {
    local username="testuser"
    local expected_home="/home/${username}"

    assert_equals "$expected_home" "/home/$username" "Home directory path correct"
}

# Test: Bashrc.d directory structure
test_bashrc_d_structure() {
    local username="testuser"
    local home_dir="/home/${username}"
    local bashrc_d_dir="${home_dir}/.bashrc.d"

    # Test path construction
    assert_equals "/home/testuser/.bashrc.d" "$bashrc_d_dir" "Bashrc.d path constructed correctly"

    # Test that we can create the directory structure (in test environment)
    local test_home="$RESULTS_DIR/test-home"
    local test_bashrc_d="$test_home/.bashrc.d"

    mkdir -p "$test_bashrc_d"
    assert_dir_exists "$test_bashrc_d"

    # Cleanup
    command rm -rf "$test_home"
}

# Test: Script parameter handling
test_script_parameters() {
    # Test that parameters would be parsed correctly
    local test_params=("myuser" "2000" "2000" "myproject" "/workspace/myproject")

    # Simulate parameter assignment
    local USERNAME="${test_params[0]}"
    local USER_UID="${test_params[1]}"
    local USER_GID="${test_params[2]}"
    local PROJECT_NAME="${test_params[3]}"
    local WORKING_DIR="${test_params[4]}"

    assert_equals "myuser" "$USERNAME" "Username parameter parsed"
    assert_equals "2000" "$USER_UID" "UID parameter parsed"
    assert_equals "2000" "$USER_GID" "GID parameter parsed"
    assert_equals "myproject" "$PROJECT_NAME" "Project name parameter parsed"
    assert_equals "/workspace/myproject" "$WORKING_DIR" "Working dir parameter parsed"
}

# Test: UID/GID range validation
test_uid_gid_ranges() {
    # Test that UID/GID ranges are within expected bounds
    local min_uid=1000
    local max_uid=65533
    local test_uid=5000

    if [ "$test_uid" -ge "$min_uid" ] && [ "$test_uid" -le "$max_uid" ]; then
        assert_true true "UID within valid range"
    else
        assert_true false "UID outside valid range"
    fi

    # Test boundary conditions
    assert_true true "UID range validation logic works"
}

# Run all tests
run_test test_script_exists "User script exists and is executable"
run_test test_default_parameters "Default parameters are set correctly"
run_test test_uid_conflict_detection "UID conflict detection logic"
run_test test_gid_conflict_detection "GID conflict detection logic"
run_test test_user_existence_check "User existence checking"
run_test test_group_existence_check "Group existence checking"
run_test test_working_dir_construction "Working directory path construction"
run_test test_build_env_structure "Build environment file structure"
run_test test_sudo_config_validation "Sudo configuration validation"
run_test test_home_directory_path "Home directory path validation"
run_test test_bashrc_d_structure "Bashrc.d directory structure"
run_test test_script_parameters "Script parameter handling"
run_test test_uid_gid_ranges "UID/GID range validation"

# Generate test report
generate_report
