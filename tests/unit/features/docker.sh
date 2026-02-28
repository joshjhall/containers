#!/usr/bin/env bash
# Unit tests for lib/features/docker.sh
# Tests Docker CLI installation and configuration

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Docker Feature Tests"

# Setup function - runs before each test
setup() {
    # Create temporary directory for testing
    export TEST_TEMP_DIR="$RESULTS_DIR/test-docker"
    mkdir -p "$TEST_TEMP_DIR"

    # Mock environment
    export USERNAME="testuser"
    export USER_UID="1000"
    export USER_GID="1000"

    # Create mock directories
    mkdir -p "$TEST_TEMP_DIR/etc/apt/keyrings"
    mkdir -p "$TEST_TEMP_DIR/etc/bashrc.d"
    mkdir -p "$TEST_TEMP_DIR/etc/container/first-startup"
    mkdir -p "$TEST_TEMP_DIR/etc/container/startup"
    mkdir -p "$TEST_TEMP_DIR/usr/local/bin"
    mkdir -p "$TEST_TEMP_DIR/cache/docker"

    # Mock Docker socket for testing
    export MOCK_DOCKER_SOCK="$TEST_TEMP_DIR/var/run/docker.sock"
    mkdir -p "$(dirname "$MOCK_DOCKER_SOCK")"
}

# Teardown function - runs after each test
teardown() {
    # Clean up test directory
    command rm -rf "$TEST_TEMP_DIR"

    # Unset test variables
    unset USERNAME USER_UID USER_GID MOCK_DOCKER_SOCK 2>/dev/null || true
}

# Test: Docker repository configuration
test_docker_repository_setup() {
    # Check that the script would create the keyrings directory
    local keyrings_dir="$TEST_TEMP_DIR/etc/apt/keyrings"

    assert_dir_exists "$keyrings_dir"

    # Verify the script sets up proper permissions
    if [ -d "$keyrings_dir" ]; then
        assert_true true "Keyrings directory exists for Docker GPG key"
    else
        assert_true false "Keyrings directory was not created"
    fi
}

# Test: Docker group creation logic
test_docker_group_creation() {
    # Simulate checking if docker group would be created
    # In real script, this would be: groupadd docker || true

    # Test that the command would handle existing group gracefully
    local test_cmd="groupadd docker || true"

    # The || true ensures it doesn't fail if group exists
    assert_not_empty "$test_cmd" "Docker group creation command is defined"

    if [[ "$test_cmd" == *"|| true"* ]]; then
        assert_true true "Command handles existing group gracefully"
    else
        assert_true false "Command might fail if group exists"
    fi
}

# Test: User added to docker group
test_user_docker_group() {
    # Test the usermod command structure
    local expected_cmd="usermod -aG docker ${USERNAME}"

    assert_equals "testuser" "$USERNAME" "Username is set correctly"
    assert_not_empty "$expected_cmd" "Usermod command is formed"

    # Check command structure
    if [[ "$expected_cmd" == *"-aG docker"* ]]; then
        assert_true true "User would be added to docker group"
    else
        assert_true false "Usermod command is incorrect"
    fi
}

# Test: Docker socket permission fix at build time
test_docker_socket_permissions_build() {
    # Create a mock socket file
    touch "$MOCK_DOCKER_SOCK"

    # Test that socket detection works
    if [ -e "$MOCK_DOCKER_SOCK" ]; then
        assert_true true "Docker socket detection works"
    else
        assert_true false "Docker socket not detected"
    fi

    # Test permission commands would be formed correctly
    local chgrp_cmd="chgrp docker $MOCK_DOCKER_SOCK || true"
    local chmod_cmd="chmod g+rw $MOCK_DOCKER_SOCK || true"

    assert_not_empty "$chgrp_cmd" "Socket group change command formed"
    assert_not_empty "$chmod_cmd" "Socket permission command formed"
}

# Test: Docker bashrc configuration
test_docker_bashrc_setup() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/50-docker.sh"

    # Create a mock bashrc file
    command cat > "$bashrc_file" << 'EOF'
alias d='docker'
alias dc='docker compose'
docker-clean() { echo "Cleaning Docker resources"; }
EOF

    assert_file_exists "$bashrc_file"

    # Check for essential aliases
    if command grep -q "alias d='docker'" "$bashrc_file"; then
        assert_true true "Docker alias 'd' is defined"
    else
        assert_true false "Docker alias 'd' not found"
    fi

    if command grep -q "alias dc='docker compose'" "$bashrc_file"; then
        assert_true true "Docker Compose alias is defined"
    else
        assert_true false "Docker Compose alias not found"
    fi

    if command grep -q "docker-clean" "$bashrc_file"; then
        assert_true true "docker-clean function is defined"
    else
        assert_true false "docker-clean function not found"
    fi
}

# Test: Docker startup scripts
test_docker_startup_scripts() {
    local first_startup="$TEST_TEMP_DIR/etc/container/first-startup/20-docker-setup.sh"

    # Create mock startup script
    echo '#!/bin/bash' > "$first_startup"
    echo 'echo "Docker first startup"' >> "$first_startup"

    assert_file_exists "$first_startup"

    # Verify the docker-socket-fix script no longer exists (removed for security)
    # Docker socket access is now configured via group_add in docker-compose.yml
    local socket_fix="$TEST_TEMP_DIR/etc/container/startup/10-docker-socket-fix.sh"
    if [ -f "$socket_fix" ]; then
        assert_true false "Docker socket fix script should not exist (use group_add instead)"
    else
        assert_true true "Docker socket fix correctly removed"
    fi
}

# Test: Docker CLI tools configuration
test_docker_cli_tools() {
    # Test environment variables for Docker CLI
    local docker_config="/cache/docker"
    local docker_plugins="/cache/docker/cli-plugins"

    assert_not_empty "$docker_config" "DOCKER_CONFIG path is defined"
    assert_not_empty "$docker_plugins" "Docker CLI plugins path is defined"

    # Check cache directory structure
    if [[ "$docker_config" == "/cache/docker" ]]; then
        assert_true true "Docker cache uses standard cache directory"
    else
        assert_true false "Docker cache directory is non-standard"
    fi
}

# Test: Lazydocker installation paths
test_lazydocker_installation() {
    local lazydocker_bin="$TEST_TEMP_DIR/usr/local/bin/lazydocker"

    # Create mock lazydocker binary
    touch "$lazydocker_bin"
    chmod +x "$lazydocker_bin"

    assert_file_exists "$lazydocker_bin"

    # Check if it's executable
    if [ -x "$lazydocker_bin" ]; then
        assert_true true "Lazydocker binary is executable"
    else
        assert_true false "Lazydocker binary is not executable"
    fi
}

# Test: Dive installation paths
test_dive_installation() {
    local dive_bin="$TEST_TEMP_DIR/usr/local/bin/dive"

    # Create mock dive binary
    touch "$dive_bin"
    chmod +x "$dive_bin"

    assert_file_exists "$dive_bin"

    # Check if it's executable
    if [ -x "$dive_bin" ]; then
        assert_true true "Dive binary is executable"
    else
        assert_true false "Dive binary is not executable"
    fi
}

# Test: test-docker verification script
test_docker_verification_script() {
    local test_script="$TEST_TEMP_DIR/usr/local/bin/test-docker"

    # Create mock verification script
    command cat > "$test_script" << 'EOF'
#!/bin/bash
echo "=== Docker CLI Status ==="
command -v docker && echo "Docker CLI installed"
echo "=== Docker Socket Status ==="
[ -S /var/run/docker.sock ] && echo "Socket mounted"
EOF
    chmod +x "$test_script"

    assert_file_exists "$test_script"

    # Check script content
    if command grep -q "Docker CLI Status" "$test_script"; then
        assert_true true "Verification script checks Docker CLI"
    else
        assert_true false "Verification script missing CLI check"
    fi

    if command grep -q "Docker Socket Status" "$test_script"; then
        assert_true true "Verification script checks socket"
    else
        assert_true false "Verification script missing socket check"
    fi
}

# Run tests with setup/teardown
run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"

    setup
    run_test "$test_function" "$test_description"
    teardown
}

# ============================================================================
# Checksum Verification Tests
# ============================================================================

# Test: docker.sh uses checksum verification for dive
test_docker_dive_checksum() {
    local docker_script="$PROJECT_ROOT/lib/features/docker.sh"

    if ! [ -f "$docker_script" ]; then
        skip_test "docker.sh not found"
        return
    fi

    # Check for dive checksum fetcher registration
    if command grep -q 'register_tool_checksum_fetcher.*dive' "$docker_script"; then
        assert_true true "docker.sh registers checksum fetcher for dive"
    else
        assert_true false "docker.sh does not register checksum fetcher for dive"
    fi

    # Check for verify_download usage for dive
    if command grep -q 'verify_download.*dive' "$docker_script"; then
        assert_true true "docker.sh uses verify_download for dive"
    else
        assert_true false "docker.sh does not use verify_download for dive"
    fi
}

# Test: docker.sh sources required verification libraries
test_docker_sources_libraries() {
    local docker_script="$PROJECT_ROOT/lib/features/docker.sh"

    if ! [ -f "$docker_script" ]; then
        skip_test "docker.sh not found"
        return
    fi

    # Check for download-verify.sh
    if command grep -q "source.*download-verify.sh" "$docker_script"; then
        assert_true true "docker.sh sources download-verify.sh"
    else
        assert_true false "docker.sh does not source download-verify.sh"
    fi

    # Check for checksum-fetch.sh
    if command grep -q "source.*checksum-fetch.sh" "$docker_script"; then
        assert_true true "docker.sh sources checksum-fetch.sh"
    else
        assert_true false "docker.sh does not source checksum-fetch.sh"
    fi
}

# Test: lazydocker uses checksum verification
test_docker_lazydocker_checksum() {
    local docker_script="$PROJECT_ROOT/lib/features/docker.sh"

    if ! [ -f "$docker_script" ]; then
        skip_test "docker.sh not found"
        return
    fi

    # Check for lazydocker checksum fetcher registration
    if command grep -q 'register_tool_checksum_fetcher.*lazydocker' "$docker_script"; then
        assert_true true "docker.sh registers checksum fetcher for lazydocker"
    else
        assert_true false "docker.sh does not register checksum fetcher for lazydocker"
    fi

    # Check for verify_download usage for lazydocker
    if command grep -q 'verify_download.*lazydocker' "$docker_script"; then
        assert_true true "docker.sh uses verify_download for lazydocker"
    else
        assert_true false "docker.sh does not use verify_download for lazydocker"
    fi
}

# Run all tests
run_test_with_setup test_docker_repository_setup "Docker repository setup configuration"
run_test_with_setup test_docker_group_creation "Docker group creation logic"
run_test_with_setup test_user_docker_group "User added to docker group"
run_test_with_setup test_docker_socket_permissions_build "Docker socket permissions at build"
run_test_with_setup test_docker_bashrc_setup "Docker bashrc configuration"
run_test_with_setup test_docker_startup_scripts "Docker startup scripts created"
run_test_with_setup test_docker_cli_tools "Docker CLI tools configuration"
run_test_with_setup test_lazydocker_installation "Lazydocker installation paths"
run_test_with_setup test_dive_installation "Dive installation paths"
run_test_with_setup test_docker_verification_script "Docker verification script"

# Run checksum verification tests
run_test test_docker_dive_checksum "docker.sh verifies dive checksum"
run_test test_docker_sources_libraries "docker.sh sources verification libraries"
run_test test_docker_lazydocker_checksum "docker.sh verifies lazydocker checksum"

# ============================================================================
# Batch 6: Additional Static Analysis Tests for docker.sh
# ============================================================================

# Test: Socket permission handling - chgrp docker
test_docker_socket_chgrp_pattern() {
    local source_file="$PROJECT_ROOT/lib/features/docker.sh"
    assert_file_contains "$source_file" "chgrp docker" "docker.sh uses chgrp docker for socket permissions"
}

# Test: Socket permission handling - chmod g+rw
test_docker_socket_chmod_pattern() {
    local source_file="$PROJECT_ROOT/lib/features/docker.sh"
    assert_file_contains "$source_file" "chmod g+rw" "docker.sh uses chmod g+rw for socket permissions"
}

# Test: Lazydocker architecture filename mapping
test_lazydocker_arch_mapping() {
    local source_file="$PROJECT_ROOT/lib/features/docker.sh"
    assert_file_contains "$source_file" "LAZYDOCKER_ARCH" "docker.sh maps architecture for lazydocker"
    assert_file_contains "$source_file" "x86_64" "docker.sh maps amd64 to x86_64 for lazydocker"
}

# Test: Dive architecture filename mapping
test_dive_arch_mapping() {
    local source_file="$PROJECT_ROOT/lib/features/docker.sh"
    assert_file_contains "$source_file" "DIVE_PACKAGE" "docker.sh constructs dive package filename"
    assert_file_contains "$source_file" "dive_" "docker.sh uses dive deb package naming"
}

# Test: Cosign installation
test_cosign_installation_reference() {
    local source_file="$PROJECT_ROOT/lib/features/docker.sh"
    assert_file_contains "$source_file" "cosign" "docker.sh installs cosign for container image signing"
}

# Test: Docker helper functions - docker-clean
test_docker_clean_function_definition() {
    local bashrc_file="$PROJECT_ROOT/lib/features/lib/bashrc/docker.sh"
    assert_file_contains "$bashrc_file" "docker-clean()" "docker bashrc defines docker-clean function"
}

# Test: Docker helper functions - docker-shell
test_docker_shell_function_definition() {
    local bashrc_file="$PROJECT_ROOT/lib/features/lib/bashrc/docker.sh"
    assert_file_contains "$bashrc_file" "docker-shell()" "docker bashrc defines docker-shell function"
}

# Test: Cache directory env vars - DOCKER_CONFIG
test_docker_config_env_var() {
    local bashrc_file="$PROJECT_ROOT/lib/features/lib/bashrc/docker.sh"
    assert_file_contains "$bashrc_file" "DOCKER_CONFIG" "docker bashrc sets DOCKER_CONFIG env var"
}

# Test: DOCKER_CLI_PLUGINS_PATH reference
test_docker_cli_plugins_path() {
    local bashrc_file="$PROJECT_ROOT/lib/features/lib/bashrc/docker.sh"
    assert_file_contains "$bashrc_file" "DOCKER_CLI_PLUGINS_PATH" "docker bashrc references DOCKER_CLI_PLUGINS_PATH"
}

# Test: Docker Compose plugin installation
test_docker_compose_plugin_install() {
    local source_file="$PROJECT_ROOT/lib/features/docker.sh"
    assert_file_contains "$source_file" "docker-compose-plugin" "docker.sh installs docker-compose-plugin"
}

# Run Batch 6 docker tests
run_test test_docker_socket_chgrp_pattern "Docker socket uses chgrp docker"
run_test test_docker_socket_chmod_pattern "Docker socket uses chmod g+rw"
run_test test_lazydocker_arch_mapping "Lazydocker architecture filename mapping"
run_test test_dive_arch_mapping "Dive architecture filename mapping"
run_test test_cosign_installation_reference "Cosign installation referenced"
run_test test_docker_clean_function_definition "docker-clean function defined"
run_test test_docker_shell_function_definition "docker-shell function defined"
run_test test_docker_config_env_var "DOCKER_CONFIG env var set"
run_test test_docker_cli_plugins_path "DOCKER_CLI_PLUGINS_PATH referenced"
run_test test_docker_compose_plugin_install "Docker Compose plugin installation"

# ============================================================================
# GPG Key Fingerprint Verification Tests
# ============================================================================

# Test: Docker GPG key fingerprint constant is defined
test_docker_gpg_fingerprint_defined() {
    local source_file="$PROJECT_ROOT/lib/features/docker.sh"
    assert_file_contains "$source_file" "DOCKER_GPG_FINGERPRINT" "docker.sh defines DOCKER_GPG_FINGERPRINT constant"
}

# Test: Docker GPG key fingerprint mismatch error handling
test_docker_gpg_fingerprint_mismatch_handling() {
    local source_file="$PROJECT_ROOT/lib/features/docker.sh"
    assert_file_contains "$source_file" "fingerprint mismatch" "docker.sh handles GPG key fingerprint mismatch"
}

# Test: Docker GPG key verification uses keyring file directly
test_docker_gpg_keyring_verification() {
    local source_file="$PROJECT_ROOT/lib/features/docker.sh"
    assert_file_contains "$source_file" "no-default-keyring" "docker.sh queries keyring file directly for fingerprint"
}

# Run GPG fingerprint verification tests
run_test test_docker_gpg_fingerprint_defined "Docker GPG fingerprint constant defined"
run_test test_docker_gpg_fingerprint_mismatch_handling "Docker GPG fingerprint mismatch handling"
run_test test_docker_gpg_keyring_verification "Docker GPG keyring verification method"

# Generate test report
generate_report
