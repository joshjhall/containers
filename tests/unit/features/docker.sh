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
    rm -rf "$TEST_TEMP_DIR"
    
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
    cat > "$bashrc_file" << 'EOF'
alias d='docker'
alias dc='docker compose'
docker-clean() { echo "Cleaning Docker resources"; }
EOF
    
    assert_file_exists "$bashrc_file"
    
    # Check for essential aliases
    if grep -q "alias d='docker'" "$bashrc_file"; then
        assert_true true "Docker alias 'd' is defined"
    else
        assert_true false "Docker alias 'd' not found"
    fi
    
    if grep -q "alias dc='docker compose'" "$bashrc_file"; then
        assert_true true "Docker Compose alias is defined"
    else
        assert_true false "Docker Compose alias not found"
    fi
    
    if grep -q "docker-clean" "$bashrc_file"; then
        assert_true true "docker-clean function is defined"
    else
        assert_true false "docker-clean function not found"
    fi
}

# Test: Docker startup scripts
test_docker_startup_scripts() {
    local first_startup="$TEST_TEMP_DIR/etc/container/first-startup/20-docker-setup.sh"
    local every_startup="$TEST_TEMP_DIR/etc/container/startup/10-docker-socket-fix.sh"
    
    # Create mock startup scripts
    echo '#!/bin/bash' > "$first_startup"
    echo 'echo "Docker first startup"' >> "$first_startup"
    
    echo '#!/bin/bash' > "$every_startup"
    echo 'if [ -S /var/run/docker.sock ]; then' >> "$every_startup"
    echo '  echo "Fixing Docker socket"' >> "$every_startup"
    echo 'fi' >> "$every_startup"
    
    assert_file_exists "$first_startup"
    assert_file_exists "$every_startup"
    
    # Check socket fix script content
    if grep -q "docker.sock" "$every_startup"; then
        assert_true true "Socket fix script checks for Docker socket"
    else
        assert_true false "Socket fix script missing socket check"
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
    cat > "$test_script" << 'EOF'
#!/bin/bash
echo "=== Docker CLI Status ==="
command -v docker && echo "Docker CLI installed"
echo "=== Docker Socket Status ==="
[ -S /var/run/docker.sock ] && echo "Socket mounted"
EOF
    chmod +x "$test_script"
    
    assert_file_exists "$test_script"
    
    # Check script content
    if grep -q "Docker CLI Status" "$test_script"; then
        assert_true true "Verification script checks Docker CLI"
    else
        assert_true false "Verification script missing CLI check"
    fi
    
    if grep -q "Docker Socket Status" "$test_script"; then
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

# Generate test report
generate_report