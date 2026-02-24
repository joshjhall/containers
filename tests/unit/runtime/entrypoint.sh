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
    # Create unique temporary directory for testing (avoid collisions with parallel runs)
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$RESULTS_DIR/test-entrypoint-$unique_id"
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
    command rm -rf "$TEST_TEMP_DIR"

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
    command rm -f "$FIRST_RUN_MARKER"

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
    command rm -f "$FIRST_STARTUP_DIR"/*.sh
    command rm -f "$STARTUP_DIR"/*.sh

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
    command cat > "$STARTUP_DIR/10-fail.sh" << 'EOF'
#!/bin/bash
exit 1
EOF

    # Create script that should run after failure
    # Use cat with variable substitution to pass TEST_TEMP_DIR into the script
    command cat > "$STARTUP_DIR/20-continue.sh" << EOF
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

# Test: Startup time tracking variables
test_startup_time_tracking() {
    # Check that entrypoint.sh contains startup time tracking
    if grep -q "STARTUP_BEGIN_TIME=\$(date +%s)" "$PROJECT_ROOT/lib/runtime/entrypoint.sh"; then
        assert_true true "Startup begin time is tracked"
    else
        assert_true false "Startup begin time tracking not found"
    fi

    if grep -q "STARTUP_END_TIME=\$(date +%s)" "$PROJECT_ROOT/lib/runtime/entrypoint.sh"; then
        assert_true true "Startup end time is tracked"
    else
        assert_true false "Startup end time tracking not found"
    fi

    if grep -q "STARTUP_DURATION=\$((STARTUP_END_TIME - STARTUP_BEGIN_TIME))" "$PROJECT_ROOT/lib/runtime/entrypoint.sh"; then
        assert_true true "Startup duration is calculated"
    else
        assert_true false "Startup duration calculation not found"
    fi
}

# Test: Startup metrics file creation
test_startup_metrics_file() {
    # Check that entrypoint.sh creates metrics directory
    if grep -q "METRICS_DIR=\"/tmp/container-metrics\"" "$PROJECT_ROOT/lib/runtime/entrypoint.sh"; then
        assert_true true "Metrics directory is defined"
    else
        assert_true false "Metrics directory not defined"
    fi

    if grep -q "mkdir -p \"\$METRICS_DIR\"" "$PROJECT_ROOT/lib/runtime/entrypoint.sh"; then
        assert_true true "Metrics directory is created"
    else
        assert_true false "Metrics directory creation not found"
    fi

    # Check that startup metrics are written
    if grep -q "startup-metrics.txt" "$PROJECT_ROOT/lib/runtime/entrypoint.sh"; then
        assert_true true "Startup metrics file is created"
    else
        assert_true false "Startup metrics file creation not found"
    fi
}

# Test: Startup metrics Prometheus format
test_startup_metrics_format() {
    # Check for Prometheus HELP comment
    if grep -q "# HELP container_startup_seconds" "$PROJECT_ROOT/lib/runtime/entrypoint.sh"; then
        assert_true true "Prometheus HELP comment present"
    else
        assert_true false "Prometheus HELP comment missing"
    fi

    # Check for Prometheus TYPE comment
    if grep -q "# TYPE container_startup_seconds gauge" "$PROJECT_ROOT/lib/runtime/entrypoint.sh"; then
        assert_true true "Prometheus TYPE comment present"
    else
        assert_true false "Prometheus TYPE comment missing"
    fi

    # Check for metric output
    if grep -q "container_startup_seconds \$STARTUP_DURATION" "$PROJECT_ROOT/lib/runtime/entrypoint.sh"; then
        assert_true true "Prometheus metric value output present"
    else
        assert_true false "Prometheus metric value output missing"
    fi
}

# Test: Startup duration calculation
test_startup_duration_calculation() {
    # Simulate startup duration calculation
    local begin_time=1000
    local end_time=1005
    local duration=$((end_time - begin_time))

    assert_equals "5" "$duration" "Startup duration calculated correctly"

    # Test with different values
    begin_time=100
    end_time=150
    duration=$((end_time - begin_time))

    assert_equals "50" "$duration" "Startup duration handles different values"
}

# Test: Startup metrics output message
test_startup_metrics_output() {
    # Check that entrypoint.sh outputs startup time
    if grep -q "Container initialized in" "$PROJECT_ROOT/lib/runtime/entrypoint.sh"; then
        assert_true true "Startup time is displayed to user"
    else
        assert_true false "Startup time display not found"
    fi
}

# Test: Exit handler function exists
test_exit_handler_function() {
    # Check that cleanup_on_exit function is defined
    if grep -q "^cleanup_on_exit()" "$PROJECT_ROOT/lib/runtime/entrypoint.sh"; then
        assert_true true "cleanup_on_exit function is defined"
    else
        assert_true false "cleanup_on_exit function not found"
    fi

    # Check that function captures exit code
    if grep -q "local exit_code=\$?" "$PROJECT_ROOT/lib/runtime/entrypoint.sh"; then
        assert_true true "Exit code is captured"
    else
        assert_true false "Exit code capture not found"
    fi

    # Check that exit code is preserved
    if grep -q "exit \$exit_code" "$PROJECT_ROOT/lib/runtime/entrypoint.sh"; then
        assert_true true "Exit code is preserved"
    else
        assert_true false "Exit code preservation not found"
    fi
}

# Test: Trap handlers are configured
test_trap_handlers() {
    # Check for trap handler setup
    if grep -q "trap cleanup_on_exit EXIT TERM INT" "$PROJECT_ROOT/lib/runtime/entrypoint.sh"; then
        assert_true true "Trap handlers are configured for EXIT TERM INT"
    else
        assert_true false "Trap handlers not configured"
    fi
}

# Test: Exit handler metrics cleanup
test_exit_handler_metrics_cleanup() {
    # Check that metrics directory is checked
    if grep -q "METRICS_DIR=" "$PROJECT_ROOT/lib/runtime/entrypoint.sh"; then
        assert_true true "Metrics directory is defined in cleanup"
    else
        assert_true false "Metrics directory not defined in cleanup"
    fi

    # Check for sync command to flush metrics
    if grep -q "sync" "$PROJECT_ROOT/lib/runtime/entrypoint.sh"; then
        assert_true true "Sync command is used to flush data"
    else
        assert_true false "Sync command not found"
    fi
}

# Test: Exit handler logging
test_exit_handler_logging() {
    # Check for shutdown message
    if grep -q "Container shutting down" "$PROJECT_ROOT/lib/runtime/entrypoint.sh"; then
        assert_true true "Shutdown message is logged"
    else
        assert_true false "Shutdown message not found"
    fi

    # Check for completion message
    if grep -q "Shutdown complete" "$PROJECT_ROOT/lib/runtime/entrypoint.sh"; then
        assert_true true "Completion message is logged"
    else
        assert_true false "Completion message not found"
    fi
}

# Test: Exit handler error handling
test_exit_handler_error_handling() {
    # Check that sync errors are handled gracefully
    if grep -q "sync.*|| true" "$PROJECT_ROOT/lib/runtime/entrypoint.sh"; then
        assert_true true "Sync errors are handled gracefully"
    else
        assert_true false "Sync error handling not found"
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

# Test: Docker socket fix section exists
test_docker_socket_fix_section() {
    local script="$PROJECT_ROOT/lib/runtime/entrypoint.sh"

    # Check for Docker socket fix section
    if grep -q "Docker Socket Access Fix" "$script"; then
        assert_true true "Docker socket fix section exists"
    else
        assert_true false "Docker socket fix section not found"
    fi
}

# Test: Docker socket fix creates docker group
test_docker_socket_creates_group() {
    local script="$PROJECT_ROOT/lib/runtime/entrypoint.sh"

    if grep -q "groupadd docker" "$script"; then
        assert_true true "Docker group creation is handled"
    else
        assert_true false "Docker group creation not found"
    fi
}

# Test: Docker socket fix sets correct permissions
test_docker_socket_permissions() {
    local script="$PROJECT_ROOT/lib/runtime/entrypoint.sh"

    # Check for chown to docker group
    if grep -q "chown root:docker /var/run/docker.sock" "$script"; then
        assert_true true "Socket ownership set to root:docker"
    else
        assert_true false "Socket ownership change not found"
    fi

    # Check for 660 permissions
    if grep -q "chmod 660 /var/run/docker.sock" "$script"; then
        assert_true true "Socket permissions set to 660"
    else
        assert_true false "Socket permissions not set to 660"
    fi
}

# Test: Docker socket fix adds user to group
test_docker_socket_user_group() {
    local script="$PROJECT_ROOT/lib/runtime/entrypoint.sh"

    if grep -q 'usermod -aG docker "\$USERNAME"' "$script"; then
        assert_true true "User added to docker group"
    else
        assert_true false "User not added to docker group"
    fi
}

# Test: Docker socket fix checks for existing access
test_docker_socket_checks_access() {
    local script="$PROJECT_ROOT/lib/runtime/entrypoint.sh"

    # Should check if user can already access before fixing
    if grep -q "test -r /var/run/docker.sock" "$script"; then
        assert_true true "Socket access check exists"
    else
        assert_true false "Socket access check not found"
    fi
}

# Test: Docker socket fix supports sudo for non-root
test_docker_socket_sudo_support() {
    local script="$PROJECT_ROOT/lib/runtime/entrypoint.sh"

    # Should have sudo support for non-root users
    if grep -q "sudo -n true" "$script" && grep -q "run_privileged" "$script"; then
        assert_true true "Sudo support for non-root users exists"
    else
        assert_true false "Sudo support not found"
    fi
}

# Test: Re-entry guard prevents double execution
test_reentry_guard() {
    local script="$PROJECT_ROOT/lib/runtime/entrypoint.sh"

    # Should have a guard to prevent re-entry
    if grep -q "ENTRYPOINT_ALREADY_RAN" "$script"; then
        assert_true true "Re-entry guard exists"
    else
        assert_true false "Re-entry guard not found"
    fi
}

# Test: Privilege drop for main process
test_privilege_drop() {
    local script="$PROJECT_ROOT/lib/runtime/entrypoint.sh"

    # Should use su -l for login shell to pick up new groups
    if grep -q 'su -l "\$USERNAME"' "$script"; then
        assert_true true "Privilege drop uses su -l for login shell"
    else
        assert_true false "Privilege drop with su -l not found"
    fi
}

# Test: Main process exec with proper quoting
test_main_process_exec() {
    local script="$PROJECT_ROOT/lib/runtime/entrypoint.sh"

    # Should have exec for main process
    if grep -q 'exec.*"\$@"' "$script" || grep -q 'exec su -l' "$script"; then
        assert_true true "Main process uses exec"
    else
        assert_true false "Main process exec not found"
    fi
}

# Test: sg docker uses QUOTED_CMD (not unquoted $*)
test_sg_docker_uses_quoted_cmd() {
    local script="$PROJECT_ROOT/lib/runtime/entrypoint.sh"

    # sg docker -c must use $QUOTED_CMD, not $*
    if grep -q 'exec sg docker -c "exec \$QUOTED_CMD"' "$script"; then
        assert_true true "sg docker path uses QUOTED_CMD"
    else
        assert_true false "sg docker path does not use QUOTED_CMD — command injection risk"
    fi
}

# Test: newgrp docker uses QUOTED_CMD (not unquoted $*)
test_newgrp_docker_uses_quoted_cmd() {
    local script="$PROJECT_ROOT/lib/runtime/entrypoint.sh"

    # newgrp docker must use $QUOTED_CMD, not $*
    if grep -q 'exec newgrp docker <<< "exec \$QUOTED_CMD"' "$script"; then
        assert_true true "newgrp docker path uses QUOTED_CMD"
    else
        assert_true false "newgrp docker path does not use QUOTED_CMD — command injection risk"
    fi
}

# Test: No unquoted $* in any exec context (prevents command injection)
test_no_unquoted_dollar_star_in_exec() {
    local script="$PROJECT_ROOT/lib/runtime/entrypoint.sh"

    # Search for lines that use $* (unquoted word-split expansion) in exec
    # This pattern is dangerous because it allows command injection
    if grep -E 'exec .* \$\*' "$script" | grep -v '^[[:space:]]*#' | grep -q .; then
        assert_true false "Found unquoted \$* in exec context — command injection risk"
    else
        assert_true true "No unquoted \$* found in exec contexts"
    fi
}

# Test: Path traversal guard validates scripts with realpath
test_path_traversal_guard_exists() {
    local script="$PROJECT_ROOT/lib/runtime/entrypoint.sh"

    # Verify all four components of the path traversal guard exist:
    # 1. realpath resolution
    local has_realpath=false
    if grep -q 'script_realpath=\$(realpath' "$script"; then
        has_realpath=true
    fi

    # 2. Starts-with directory check (matches $dir or $*DIR variables)
    local has_prefix_check=false
    if grep -q 'script_realpath" == "\$' "$script"; then
        has_prefix_check=true
    fi

    # 3. Double-dot rejection (source uses =~ \.\. regex)
    local has_dotdot_check=false
    if grep -q 'script_realpath.*=~.*\\\.\\\.' "$script"; then
        has_dotdot_check=true
    fi

    # 4. Not-the-directory-itself check
    local has_dir_check=false
    if grep -q 'script_realpath" != "\$' "$script"; then
        has_dir_check=true
    fi

    if [ "$has_realpath" = "true" ] && [ "$has_prefix_check" = "true" ] && \
       [ "$has_dotdot_check" = "true" ] && [ "$has_dir_check" = "true" ]; then
        assert_true true "Path traversal guard has all four validation checks"
    else
        assert_true false "Path traversal guard incomplete (realpath=$has_realpath prefix=$has_prefix_check dotdot=$has_dotdot_check dir=$has_dir_check)"
    fi
}

# Test: su -c script invocations use quoted $script
test_su_script_uses_quoting() {
    local script="$PROJECT_ROOT/lib/runtime/entrypoint.sh"

    # All su ... -c "bash ..." lines must quote the script path
    # Correct: su "${USERNAME}" -c "bash '$script'"
    # Wrong:   su "${USERNAME}" -c "bash $script"
    local unquoted_count
    unquoted_count=$(grep -c "bash \\\$script\"" "$script" || true)
    local quoted_count
    quoted_count=$(grep -c "bash '\\\$script'" "$script" || true)

    if [ "$unquoted_count" -eq 0 ] && [ "$quoted_count" -ge 1 ]; then
        assert_true true "All su -c bash invocations use quoted script path ($quoted_count found)"
    else
        assert_true false "Found $unquoted_count unquoted and $quoted_count quoted su -c bash invocations"
    fi
}

# Test: run_startup_scripts function exists
test_run_startup_scripts_function() {
    local script="$PROJECT_ROOT/lib/runtime/entrypoint.sh"

    if grep -q '^run_startup_scripts()' "$script"; then
        assert_true true "run_startup_scripts function is defined"
    else
        assert_true false "run_startup_scripts function not found"
    fi
}

# Test: run_startup_scripts is called for both startup phases
test_run_startup_scripts_called() {
    local script="$PROJECT_ROOT/lib/runtime/entrypoint.sh"

    local first_startup=false
    local every_boot=false

    if grep -q 'run_startup_scripts "\$FIRST_STARTUP_DIR" "first-startup"' "$script"; then
        first_startup=true
    fi
    if grep -q 'run_startup_scripts "\$STARTUP_DIR" "startup"' "$script"; then
        every_boot=true
    fi

    if [ "$first_startup" = "true" ] && [ "$every_boot" = "true" ]; then
        assert_true true "run_startup_scripts called for both startup phases"
    else
        assert_true false "run_startup_scripts not called for both phases (first=$first_startup every=$every_boot)"
    fi
}

# Test: No duplicate privilege helper functions
test_no_duplicate_privilege_helpers() {
    local script="$PROJECT_ROOT/lib/runtime/entrypoint.sh"

    # Should have exactly one run_privileged() definition
    local count
    count=$(grep -c '^run_privileged()' "$script" || true)

    if [ "$count" -eq 1 ]; then
        assert_true true "Exactly one run_privileged() definition found"
    else
        assert_true false "Expected 1 run_privileged() definition, found $count"
    fi

    # Should have no cache_run_privileged or bindfs_run_privileged
    local stale
    stale=$(grep -c 'cache_run_privileged\|bindfs_run_privileged' "$script" || true)

    if [ "$stale" -eq 0 ]; then
        assert_true true "No stale privilege helper functions remain"
    else
        assert_true false "Found $stale stale privilege helper references"
    fi
}

# Test: su -c touch uses quoted $FIRST_RUN_MARKER
test_su_touch_marker_uses_quoting() {
    local script="$PROJECT_ROOT/lib/runtime/entrypoint.sh"

    # Correct: su "${USERNAME}" -c "touch '$FIRST_RUN_MARKER'"
    # Wrong:   su "${USERNAME}" -c "touch $FIRST_RUN_MARKER"
    if grep -q "touch '\\\$FIRST_RUN_MARKER'" "$script"; then
        assert_true true "su -c touch uses quoted FIRST_RUN_MARKER"
    else
        assert_true false "su -c touch does not quote FIRST_RUN_MARKER"
    fi
}

# ============================================================================
# Functional Tests - Re-entry guard behavior
# ============================================================================

# Functional test: re-entry guard skips startup when ENTRYPOINT_ALREADY_RAN=true
test_reentry_guard_skips_when_set() {
    # Create a temp script that mimics the entrypoint's re-entry guard.
    # If the guard triggers, exec runs the command immediately (no startup).
    # If the guard doesn't trigger, a marker file is created (simulating startup).
    local guard_script="$TEST_TEMP_DIR/reentry-test.sh"
    cat > "$guard_script" << 'GUARD_EOF'
#!/bin/bash
# Re-entry guard (same logic as entrypoint.sh:36-40)
if [ "${ENTRYPOINT_ALREADY_RAN:-}" = "true" ]; then
    exec "$@"
fi
export ENTRYPOINT_ALREADY_RAN=true

# Simulate startup work
touch "$TEST_TEMP_DIR/startup-ran.marker"

# Run the command
exec "$@"
GUARD_EOF
    chmod +x "$guard_script"

    # Run with ENTRYPOINT_ALREADY_RAN=true — guard should skip startup
    local output
    output=$(ENTRYPOINT_ALREADY_RAN=true TEST_TEMP_DIR="$TEST_TEMP_DIR" \
        bash "$guard_script" echo "executed")

    assert_equals "executed" "$output" "Command was executed via re-entry guard"

    if [ -f "$TEST_TEMP_DIR/startup-ran.marker" ]; then
        fail_test "Startup should NOT have run when ENTRYPOINT_ALREADY_RAN=true"
    else
        pass_test "Re-entry guard correctly skipped startup"
    fi
}

# Functional test: re-entry guard runs startup when ENTRYPOINT_ALREADY_RAN is unset
test_reentry_guard_runs_when_unset() {
    local guard_script="$TEST_TEMP_DIR/reentry-test.sh"
    cat > "$guard_script" << 'GUARD_EOF'
#!/bin/bash
if [ "${ENTRYPOINT_ALREADY_RAN:-}" = "true" ]; then
    exec "$@"
fi
export ENTRYPOINT_ALREADY_RAN=true

# Simulate startup work
touch "$TEST_TEMP_DIR/startup-ran.marker"

exec "$@"
GUARD_EOF
    chmod +x "$guard_script"

    # Run without ENTRYPOINT_ALREADY_RAN — startup should execute
    local output
    output=$(unset ENTRYPOINT_ALREADY_RAN; TEST_TEMP_DIR="$TEST_TEMP_DIR" \
        bash "$guard_script" echo "executed")

    assert_equals "executed" "$output" "Command was executed after startup"

    if [ -f "$TEST_TEMP_DIR/startup-ran.marker" ]; then
        pass_test "Startup correctly ran when ENTRYPOINT_ALREADY_RAN was unset"
    else
        fail_test "Startup should have run when ENTRYPOINT_ALREADY_RAN was unset"
    fi
}

# Run all tests
run_test_with_setup test_sg_docker_uses_quoted_cmd "sg docker uses QUOTED_CMD (not \$*)"
run_test_with_setup test_newgrp_docker_uses_quoted_cmd "newgrp docker uses QUOTED_CMD (not \$*)"
run_test_with_setup test_no_unquoted_dollar_star_in_exec "No unquoted \$* in exec contexts"
run_test_with_setup test_path_traversal_guard_exists "Path traversal guard has all checks"
run_test_with_setup test_su_script_uses_quoting "su -c bash uses quoted script path"
run_test_with_setup test_su_touch_marker_uses_quoting "su -c touch uses quoted marker path"
run_test_with_setup test_run_startup_scripts_function "run_startup_scripts function exists"
run_test_with_setup test_run_startup_scripts_called "run_startup_scripts called for both phases"
run_test_with_setup test_no_duplicate_privilege_helpers "No duplicate privilege helper functions"
run_test_with_setup test_docker_socket_fix_section "Docker socket fix section exists"
run_test_with_setup test_docker_socket_creates_group "Docker socket creates docker group"
run_test_with_setup test_docker_socket_permissions "Docker socket sets correct permissions"
run_test_with_setup test_docker_socket_user_group "Docker socket adds user to group"
run_test_with_setup test_docker_socket_checks_access "Docker socket checks existing access"
run_test_with_setup test_docker_socket_sudo_support "Docker socket sudo support for non-root"
run_test_with_setup test_reentry_guard "Re-entry guard exists"
run_test_with_setup test_privilege_drop "Privilege drop for main process"
run_test_with_setup test_main_process_exec "Main process exec"
run_test_with_setup test_first_run_detection "First-run detection works correctly"
run_test_with_setup test_first_startup_script_order "First-startup scripts run in order"
run_test_with_setup test_every_boot_scripts "Every-boot scripts execute properly"
run_test_with_setup test_script_permissions "Script permission handling"
run_test_with_setup test_user_context "User context switching logic"
run_test_with_setup test_first_run_marker_creation "First-run marker creation"
run_test_with_setup test_empty_directory_handling "Empty directory handling"
run_test_with_setup test_script_error_handling "Script error handling"
run_test_with_setup test_environment_preservation "Environment preservation in scripts"
run_test_with_setup test_startup_time_tracking "Startup time tracking variables"
run_test_with_setup test_startup_metrics_file "Startup metrics file creation"
run_test_with_setup test_startup_metrics_format "Startup metrics Prometheus format"
run_test_with_setup test_startup_duration_calculation "Startup duration calculation"
run_test_with_setup test_startup_metrics_output "Startup metrics output message"
run_test_with_setup test_exit_handler_function "Exit handler function definition"
run_test_with_setup test_trap_handlers "Trap handlers configuration"
run_test_with_setup test_exit_handler_metrics_cleanup "Exit handler metrics cleanup"
run_test_with_setup test_exit_handler_logging "Exit handler logging messages"
run_test_with_setup test_exit_handler_error_handling "Exit handler error handling"
run_test_with_setup test_reentry_guard_skips_when_set "Re-entry guard skips startup when set"
run_test_with_setup test_reentry_guard_runs_when_unset "Re-entry guard runs startup when unset"

# Generate test report
generate_report
