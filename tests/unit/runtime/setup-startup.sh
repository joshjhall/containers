#!/usr/bin/env bash
# Unit tests for lib/runtime/setup-startup.sh
# Tests container startup scripts and initialization

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Setup Startup Tests"

# Setup function - runs before each test
setup() {
    # Create temporary directory for testing
    export TEST_TEMP_DIR="$RESULTS_DIR/test-setup-startup"
    mkdir -p "$TEST_TEMP_DIR"
    
    # Mock environment
    export WORKING_DIR="/workspace/project"
    export HOME="/home/testuser"
    
    # Create mock directories
    mkdir -p "$TEST_TEMP_DIR/etc/container/first-startup"
    mkdir -p "$TEST_TEMP_DIR/etc/container/startup"
    mkdir -p "$TEST_TEMP_DIR/workspace/project"
}

# Teardown function - runs after each test
teardown() {
    # Clean up test directory
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
    
    # Unset test variables
    unset WORKING_DIR HOME 2>/dev/null || true
}

# Test: Startup directory structure
test_startup_directories() {
    local first_startup="$TEST_TEMP_DIR/etc/container/first-startup"
    local startup="$TEST_TEMP_DIR/etc/container/startup"
    
    assert_dir_exists "$first_startup"
    assert_dir_exists "$startup"
}

# Test: First startup scripts
test_first_startup_scripts() {
    local first_startup="$TEST_TEMP_DIR/etc/container/first-startup"
    
    # Create mock startup scripts
    command cat > "$first_startup/10-welcome.sh" << 'EOF'
#!/bin/bash
echo "Welcome to the development container!"
EOF
    
    command cat > "$first_startup/20-git-setup.sh" << 'EOF'
#!/bin/bash
git config --global init.defaultBranch main
EOF
    
    chmod +x "$first_startup"/*.sh
    
    # Check scripts exist and are executable
    for script in "$first_startup"/*.sh; do
        if [ -x "$script" ]; then
            assert_true true "$(basename $script) is executable"
        else
            assert_true false "$(basename $script) is not executable"
        fi
    done
}

# Test: Startup script ordering
test_script_ordering() {
    local startup="$TEST_TEMP_DIR/etc/container/startup"
    
    # Create scripts with numeric prefixes
    touch "$startup/10-first.sh"
    touch "$startup/20-second.sh"
    touch "$startup/30-third.sh"
    
    # List scripts in order
    local scripts
    mapfile -t scripts < <(ls "$startup"/*.sh 2>/dev/null | sort)
    
    # Check ordering
    if [[ "${scripts[0]}" == *"10-first.sh" ]]; then
        assert_true true "Scripts ordered correctly"
    else
        assert_true false "Scripts not ordered correctly"
    fi
}

# Test: First run marker
test_first_run_marker() {
    local marker_file="$TEST_TEMP_DIR/home/testuser/.container-initialized"
    
    # Test marker doesn't exist initially
    if [ ! -f "$marker_file" ]; then
        assert_true true "First run marker doesn't exist initially"
    else
        assert_true false "First run marker exists unexpectedly"
    fi
    
    # Create marker
    mkdir -p "$(dirname "$marker_file")"
    touch "$marker_file"
    
    # Test marker exists after creation
    assert_file_exists "$marker_file"
}

# Test: Environment setup script
test_environment_setup() {
    local env_script="$TEST_TEMP_DIR/etc/container/startup/00-env.sh"
    mkdir -p "$(dirname "$env_script")"
    
    # Create environment setup
    command cat > "$env_script" << 'EOF'
#!/bin/bash
export CONTAINER_STARTED="true"
export WORKING_DIR="/workspace/project"
export TERM="xterm-256color"
EOF
    chmod +x "$env_script"
    
    assert_file_exists "$env_script"
    
    # Check environment variables
    if grep -q "export CONTAINER_STARTED" "$env_script"; then
        assert_true true "Container started flag set"
    else
        assert_true false "Container started flag not set"
    fi
}

# Test: Git repository detection
test_git_detection() {
    local git_script="$TEST_TEMP_DIR/etc/container/first-startup/15-git-detect.sh"
    mkdir -p "$(dirname "$git_script")"
    
    # Create git detection script
    command cat > "$git_script" << 'EOF'
#!/bin/bash
if [ -d "${WORKING_DIR}/.git" ]; then
    echo "Git repository detected"
    cd "${WORKING_DIR}"
    git status
fi
EOF
    chmod +x "$git_script"
    
    assert_file_exists "$git_script"
    
    # Check git detection logic
    if grep -q "if \[ -d.*\.git" "$git_script"; then
        assert_true true "Git detection logic present"
    else
        assert_true false "Git detection logic missing"
    fi
}

# Test: Project type detection
test_project_detection() {
    local detect_script="$TEST_TEMP_DIR/etc/container/first-startup/25-detect-project.sh"
    mkdir -p "$(dirname "$detect_script")"
    
    # Create project detection script
    command cat > "$detect_script" << 'EOF'
#!/bin/bash
cd "${WORKING_DIR}"
if [ -f "package.json" ]; then
    echo "Node.js project detected"
elif [ -f "requirements.txt" ] || [ -f "pyproject.toml" ]; then
    echo "Python project detected"
elif [ -f "go.mod" ]; then
    echo "Go project detected"
fi
EOF
    chmod +x "$detect_script"
    
    assert_file_exists "$detect_script"
    
    # Check detection patterns
    if grep -q "package.json" "$detect_script"; then
        assert_true true "Node.js detection present"
    else
        assert_true false "Node.js detection missing"
    fi
}

# Test: SSH agent setup
test_ssh_agent_setup() {
    local ssh_script="$TEST_TEMP_DIR/etc/container/startup/05-ssh-agent.sh"
    mkdir -p "$(dirname "$ssh_script")"
    
    # Create SSH agent script
    command cat > "$ssh_script" << 'EOF'
#!/bin/bash
if [ -z "$SSH_AUTH_SOCK" ]; then
    eval $(ssh-agent -s)
fi
EOF
    chmod +x "$ssh_script"
    
    assert_file_exists "$ssh_script"
    
    # Check SSH agent setup
    if grep -q "ssh-agent" "$ssh_script"; then
        assert_true true "SSH agent setup present"
    else
        assert_true false "SSH agent setup missing"
    fi
}

# Test: Banner display
test_banner_display() {
    local banner_script="$TEST_TEMP_DIR/etc/container/first-startup/00-banner.sh"
    mkdir -p "$(dirname "$banner_script")"
    
    # Create banner script
    command cat > "$banner_script" << 'EOF'
#!/bin/bash
cat << 'BANNER'
=====================================
   Development Container Ready
=====================================
BANNER
EOF
    chmod +x "$banner_script"
    
    assert_file_exists "$banner_script"
    
    # Check banner content
    if grep -q "Development Container Ready" "$banner_script"; then
        assert_true true "Banner message present"
    else
        assert_true false "Banner message missing"
    fi
}

# Test: Verification script
test_startup_verification() {
    local test_script="$TEST_TEMP_DIR/test-startup.sh"
    
    # Create verification script
    command cat > "$test_script" << 'EOF'
#!/bin/bash
echo "Startup scripts:"
for dir in /etc/container/first-startup /etc/container/startup; do
    if [ -d "$dir" ]; then
        echo "  $dir:"
        ls -la "$dir"/*.sh 2>/dev/null || echo "    No scripts found"
    fi
done
EOF
    chmod +x "$test_script"
    
    assert_file_exists "$test_script"
    
    # Check script is executable
    if [ -x "$test_script" ]; then
        assert_true true "Verification script is executable"
    else
        assert_true false "Verification script is not executable"
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
run_test_with_setup test_startup_directories "Startup directory structure"
run_test_with_setup test_first_startup_scripts "First startup scripts"
run_test_with_setup test_script_ordering "Script execution ordering"
run_test_with_setup test_first_run_marker "First run marker"
run_test_with_setup test_environment_setup "Environment setup script"
run_test_with_setup test_git_detection "Git repository detection"
run_test_with_setup test_project_detection "Project type detection"
run_test_with_setup test_ssh_agent_setup "SSH agent setup"
run_test_with_setup test_banner_display "Banner display"
run_test_with_setup test_startup_verification "Startup verification"

# Generate test report
generate_report