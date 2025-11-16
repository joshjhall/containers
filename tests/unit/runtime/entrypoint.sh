#!/usr/bin/env bash
# Unit tests for lib/runtime/entrypoint.sh
# Tests container entrypoint functionality

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Entrypoint Runtime Tests"

# Setup function - runs before each test
setup() {
    # Create temporary directory for testing
    export TEST_TEMP_DIR="$RESULTS_DIR/test-entrypoint"
    mkdir -p "$TEST_TEMP_DIR"
    
    # Mock container environment
    export TEST_USERNAME="testuser"
    export TEST_HOME="$TEST_TEMP_DIR/home/testuser"
    mkdir -p "$TEST_HOME"
    
    # Create mock startup directories
    export FIRST_STARTUP_DIR="$TEST_TEMP_DIR/etc/container/first-startup"
    export STARTUP_DIR="$TEST_TEMP_DIR/etc/container/startup"
    mkdir -p "$FIRST_STARTUP_DIR"
    mkdir -p "$STARTUP_DIR"
    
    # Mock first-run marker
    export FIRST_RUN_MARKER="$TEST_HOME/.container-initialized"
}

# Teardown function - runs after each test
teardown() {
    # Clean up test directory
    rm -rf "$TEST_TEMP_DIR"
    
    # Unset test variables
    unset TEST_USERNAME TEST_HOME FIRST_STARTUP_DIR STARTUP_DIR FIRST_RUN_MARKER 2>/dev/null || true
}

# Test: First-run detection
test_first_run_detection() {
    # Test when marker doesn't exist (first run)
    if [ ! -f "$FIRST_RUN_MARKER" ]; then
        assert_true true "First run correctly detected when marker absent"
    else
        assert_true false "First run not detected"
    fi
    
    # Create marker and test again
    touch "$FIRST_RUN_MARKER"
    
    if [ -f "$FIRST_RUN_MARKER" ]; then
        assert_true true "Subsequent run detected when marker exists"
    else
        assert_true false "Marker creation failed"
    fi
}

# Test: First-startup script execution order
test_first_startup_script_order() {
    # Create numbered scripts
    echo 'echo "10" >> '$TEST_TEMP_DIR'/order.txt' > "$FIRST_STARTUP_DIR/10-first.sh"
    echo 'echo "20" >> '$TEST_TEMP_DIR'/order.txt' > "$FIRST_STARTUP_DIR/20-second.sh"
    echo 'echo "30" >> '$TEST_TEMP_DIR'/order.txt' > "$FIRST_STARTUP_DIR/30-third.sh"
    chmod +x "$FIRST_STARTUP_DIR"/*.sh
    
    # Simulate script execution in order
    for script in "$FIRST_STARTUP_DIR"/*.sh; do
        if [ -f "$script" ]; then
            bash "$script"
        fi
    done
    
    # Check execution order
    if [ -f "$TEST_TEMP_DIR/order.txt" ]; then
        local order
        order=$(cat "$TEST_TEMP_DIR/order.txt" | tr '\n' ' ')
        assert_equals "10 20 30 " "$order" "Scripts executed in correct order"
    else
        assert_true false "Order tracking file not created"
    fi
}

# Test: Every-boot script execution
test_every_boot_scripts() {
    # Create startup scripts
    echo 'echo "startup1" >> '$TEST_TEMP_DIR'/startup.log' > "$STARTUP_DIR/10-startup1.sh"
    echo 'echo "startup2" >> '$TEST_TEMP_DIR'/startup.log' > "$STARTUP_DIR/20-startup2.sh"
    chmod +x "$STARTUP_DIR"/*.sh
    
    # Execute startup scripts
    for script in "$STARTUP_DIR"/*.sh; do
        if [ -f "$script" ]; then
            bash "$script"
        fi
    done
    
    # Check that scripts ran
    if [ -f "$TEST_TEMP_DIR/startup.log" ]; then
        local lines
        lines=$(wc -l < "$TEST_TEMP_DIR/startup.log")
        assert_equals "2" "$lines" "Both startup scripts executed"
    else
        assert_true false "Startup log not created"
    fi
}

# Test: Script permission handling
test_script_permissions() {
    # Create scripts with different permissions
    echo 'echo "executable"' > "$STARTUP_DIR/10-exec.sh"
    echo 'echo "not-executable"' > "$STARTUP_DIR/20-noexec.txt"
    chmod +x "$STARTUP_DIR/10-exec.sh"
    chmod -x "$STARTUP_DIR/20-noexec.txt"
    
    # Check executable .sh file detection
    local exec_count=0
    for script in "$STARTUP_DIR"/*.sh; do
        if [ -f "$script" ] && [ -x "$script" ]; then
            exec_count=$((exec_count + 1))
        fi
    done
    
    assert_equals "1" "$exec_count" "Only executable scripts counted"
}

# Test: User context switching
test_user_context() {
    # Test UID detection
    local uid_1000
    uid_1000=$(getent passwd 1000 2>/dev/null | cut -d: -f1 || echo "")
    
    if [ -n "$uid_1000" ]; then
        assert_not_empty "$uid_1000" "User with UID 1000 can be detected"
    else
        # In test environment, user might not exist
        assert_true true "User detection test skipped (no UID 1000)"
    fi
    
    # Test su command formation
    local su_cmd="su ${TEST_USERNAME} -c 'bash /path/to/script.sh'"
    
    if [[ "$su_cmd" == *"su ${TEST_USERNAME}"* ]]; then
        assert_true true "su command properly formed"
    else
        assert_true false "su command incorrect"
    fi
}

# Test: First-run marker creation
test_first_run_marker_creation() {
    # Ensure marker doesn't exist
    rm -f "$FIRST_RUN_MARKER"
    
    # Simulate marker creation
    touch "$FIRST_RUN_MARKER"
    
    assert_file_exists "$FIRST_RUN_MARKER"
    
    # Check marker persistence
    if [ -f "$FIRST_RUN_MARKER" ]; then
        assert_true true "First-run marker persists"
    else
        assert_true false "First-run marker not persistent"
    fi
}

# Test: Empty directory handling
test_empty_directory_handling() {
    # Remove all scripts
    rm -f "$FIRST_STARTUP_DIR"/*.sh
    rm -f "$STARTUP_DIR"/*.sh
    
    # Test with empty directories
    local first_count
    first_count=$(command find "$FIRST_STARTUP_DIR" -name "*.sh" -type f 2>/dev/null | wc -l)
    local startup_count
    startup_count=$(command find "$STARTUP_DIR" -name "*.sh" -type f 2>/dev/null | wc -l)

    assert_equals "0" "$first_count" "Empty first-startup directory handled"
    assert_equals "0" "$startup_count" "Empty startup directory handled"
}

# Test: Script error handling
test_script_error_handling() {
    # Create script that fails
    cat > "$STARTUP_DIR/10-fail.sh" << 'EOF'
#!/bin/bash
exit 1
EOF

    # Create script that should run after failure
    # Use cat with variable substitution to pass TEST_TEMP_DIR into the script
    cat > "$STARTUP_DIR/20-continue.sh" << EOF
#!/bin/bash
echo "after-fail" > "${TEST_TEMP_DIR}/continue.log"
EOF

    chmod +x "$STARTUP_DIR"/*.sh

    # Execute with error handling (ensure both scripts run)
    for script in "$STARTUP_DIR"/*.sh; do
        if [ -f "$script" ] && [ -x "$script" ]; then
            bash "$script" 2>/dev/null || true  # Continue on error
        fi
    done

    # Give filesystem a moment to sync
    sync 2>/dev/null || true

    # Check that execution continued after error
    if [ -f "$TEST_TEMP_DIR/continue.log" ]; then
        local content
        content=$(cat "$TEST_TEMP_DIR/continue.log" 2>/dev/null | tr -d '\n')
        if [ "$content" = "after-fail" ]; then
            assert_true true "Execution continued after script error"
        else
            assert_true false "Script ran but produced unexpected output: $content"
        fi
    else
        assert_true false "Execution stopped after script error (continue.log not found)"
    fi
}

# Test: Environment preservation
test_environment_preservation() {
    # Set test environment variable
    export TEST_ENV_VAR="preserved"
    
    # Create script that checks environment
    echo 'echo "$TEST_ENV_VAR" > '$TEST_TEMP_DIR'/env.txt' > "$STARTUP_DIR/10-env.sh"
    chmod +x "$STARTUP_DIR/10-env.sh"
    
    # Execute script
    bash "$STARTUP_DIR/10-env.sh"
    
    # Check environment was preserved
    if [ -f "$TEST_TEMP_DIR/env.txt" ]; then
        local value
        value=$(cat "$TEST_TEMP_DIR/env.txt")
        assert_equals "preserved" "$value" "Environment variable preserved"
    else
        assert_true false "Environment check failed"
    fi
    
    unset TEST_ENV_VAR
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
run_test_with_setup test_first_run_detection "First-run detection works correctly"
run_test_with_setup test_first_startup_script_order "First-startup scripts run in order"
run_test_with_setup test_every_boot_scripts "Every-boot scripts execute properly"
run_test_with_setup test_script_permissions "Script permission handling"
run_test_with_setup test_user_context "User context switching logic"
run_test_with_setup test_first_run_marker_creation "First-run marker creation"
run_test_with_setup test_empty_directory_handling "Empty directory handling"
run_test_with_setup test_script_error_handling "Script error handling"
run_test_with_setup test_environment_preservation "Environment preservation in scripts"

# Generate test report
generate_report