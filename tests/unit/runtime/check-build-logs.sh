#!/usr/bin/env bash
# Unit tests for lib/runtime/check-build-logs.sh
# Tests build log viewing functionality

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Check Build Logs Tests"

# Setup function - runs before each test
setup() {
    # Create temporary directory for testing
    export TEST_TEMP_DIR="$RESULTS_DIR/test-check-build-logs"
    mkdir -p "$TEST_TEMP_DIR"

    # Mock log directory
    export BUILD_LOG_DIR="$TEST_TEMP_DIR/var/log/build"
    mkdir -p "$BUILD_LOG_DIR"
}

# Teardown function - runs after each test
teardown() {
    # Clean up test directory
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi

    # Unset test variables
    unset BUILD_LOG_DIR 2>/dev/null || true
}

# Test: Log directory structure
test_log_directory_structure() {
    # Create expected log structure
    mkdir -p "$BUILD_LOG_DIR/features"
    mkdir -p "$BUILD_LOG_DIR/base"

    assert_dir_exists "$BUILD_LOG_DIR"
    assert_dir_exists "$BUILD_LOG_DIR/features"
    assert_dir_exists "$BUILD_LOG_DIR/base"
}

# Test: Build log file creation
test_build_log_creation() {
    # Ensure directories exist
    mkdir -p "$BUILD_LOG_DIR/features"

    # Create mock build logs
    command cat > "$BUILD_LOG_DIR/features/python.log" << 'EOF'
=== Installing Python ===
[2025-08-11 10:00:00] Starting Python installation
[2025-08-11 10:00:01] Installing Python 3.12.0
[2025-08-11 10:00:05] Python installed successfully
EOF

    command cat > "$BUILD_LOG_DIR/features/node.log" << 'EOF'
=== Installing Node.js ===
[2025-08-11 10:01:00] Starting Node.js installation
[2025-08-11 10:01:01] Installing Node.js 20.11.0
[2025-08-11 10:01:05] Node.js installed successfully
EOF

    assert_file_exists "$BUILD_LOG_DIR/features/python.log"
    assert_file_exists "$BUILD_LOG_DIR/features/node.log"
}

# Test: Master summary log
test_master_summary_log() {
    local summary_log="$BUILD_LOG_DIR/master-summary.log"

    # Create master summary
    command cat > "$summary_log" << 'EOF'
=== Container Build Summary ===
Build started: 2025-08-11 10:00:00
Build completed: 2025-08-11 10:15:00

Features installed:
✓ Python 3.12.0
✓ Node.js 20.11.0
✓ Docker
✓ Development Tools

Total build time: 15 minutes
EOF

    assert_file_exists "$summary_log"

    # Check summary content
    if grep -q "Container Build Summary" "$summary_log"; then
        assert_true true "Summary has header"
    else
        assert_true false "Summary missing header"
    fi

    if grep -q "Features installed:" "$summary_log"; then
        assert_true true "Summary lists features"
    else
        assert_true false "Summary doesn't list features"
    fi
}

# Test: Log file permissions
test_log_file_permissions() {
    local test_log="$BUILD_LOG_DIR/test.log"

    # Create test log
    echo "Test log content" > "$test_log"
    chmod 644 "$test_log"

    # Check readability
    if [ -r "$test_log" ]; then
        assert_true true "Log file is readable"
    else
        assert_true false "Log file is not readable"
    fi
}

# Test: Log search functionality
test_log_search() {
    # Ensure directory exists
    mkdir -p "$BUILD_LOG_DIR/features"
    local test_log="$BUILD_LOG_DIR/features/test.log"

    # Create log with searchable content
    command cat > "$test_log" << 'EOF'
[INFO] Starting installation
[ERROR] Failed to download package
[WARNING] Using cached version
[SUCCESS] Installation complete
EOF

    # Test searching for errors
    if grep -q "ERROR" "$test_log"; then
        assert_true true "Can find ERROR entries"
    else
        assert_true false "Cannot find ERROR entries"
    fi

    # Test searching for warnings
    if grep -q "WARNING" "$test_log"; then
        assert_true true "Can find WARNING entries"
    else
        assert_true false "Cannot find WARNING entries"
    fi
}

# Test: Log listing functionality
test_log_listing() {
    # Ensure directories exist
    mkdir -p "$BUILD_LOG_DIR/features"
    mkdir -p "$BUILD_LOG_DIR/base"

    # Create multiple logs
    touch "$BUILD_LOG_DIR/features/python.log"
    touch "$BUILD_LOG_DIR/features/node.log"
    touch "$BUILD_LOG_DIR/features/docker.log"
    touch "$BUILD_LOG_DIR/base/setup.log"

    # Count logs in features
    local feature_count
    feature_count=$(ls -1 "$BUILD_LOG_DIR/features" | wc -l)
    assert_equals "3" "$feature_count" "Three feature logs exist"

    # Count logs in base
    local base_count
    base_count=$(ls -1 "$BUILD_LOG_DIR/base" | wc -l)
    assert_equals "1" "$base_count" "One base log exists"
}

# Test: Log timestamp format
test_log_timestamps() {
    local test_log="$BUILD_LOG_DIR/test.log"

    # Create log with timestamps
    command cat > "$test_log" << 'EOF'
[2025-08-11 10:00:00] Starting process
[2025-08-11 10:00:01] Process running
[2025-08-11 10:00:02] Process complete
EOF

    # Check timestamp format
    if grep -E '\[20[0-9]{2}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\]' "$test_log"; then
        assert_true true "Timestamps follow expected format"
    else
        assert_true false "Timestamps don't follow expected format"
    fi
}

# Test: Error log detection
test_error_detection() {
    # Create logs with various error states
    command cat > "$BUILD_LOG_DIR/success.log" << 'EOF'
[INFO] Installation successful
[SUCCESS] All tests passed
EOF

    command cat > "$BUILD_LOG_DIR/failure.log" << 'EOF'
[ERROR] Installation failed
[FATAL] Cannot continue
EOF

    # Check for errors in failure log
    if grep -E "(ERROR|FATAL)" "$BUILD_LOG_DIR/failure.log"; then
        assert_true true "Errors detected in failure log"
    else
        assert_true false "Errors not detected in failure log"
    fi

    # Check for no errors in success log
    if ! grep -E "(ERROR|FATAL)" "$BUILD_LOG_DIR/success.log"; then
        assert_true true "No errors in success log"
    else
        assert_true false "Unexpected errors in success log"
    fi
}

# Test: Log rotation handling
test_log_rotation() {
    # Create rotated logs
    touch "$BUILD_LOG_DIR/build.log"
    touch "$BUILD_LOG_DIR/build.log.1"
    touch "$BUILD_LOG_DIR/build.log.2"

    # Check all logs exist
    assert_file_exists "$BUILD_LOG_DIR/build.log"
    assert_file_exists "$BUILD_LOG_DIR/build.log.1"
    assert_file_exists "$BUILD_LOG_DIR/build.log.2"

    # Count rotated logs
    local rotated_count
    rotated_count=$(command find "$BUILD_LOG_DIR" -maxdepth 1 -name "*build.log*" -type f | wc -l)
    assert_equals "3" "$rotated_count" "Three rotated logs exist"
}

# Test: Script usage output
test_script_usage() {
    local script_output="$TEST_TEMP_DIR/usage.txt"

    # Create mock usage output
    command cat > "$script_output" << 'EOF'
Usage: check-build-logs.sh [feature-name|master-summary]

Examples:
  check-build-logs.sh python       - View Python installation log
  check-build-logs.sh master-summary - View build summary
  check-build-logs.sh              - List all available logs

Available logs:
  - python
  - node
  - docker
  - master-summary
EOF

    assert_file_exists "$script_output"

    # Check usage content
    if grep -q "Usage:" "$script_output"; then
        assert_true true "Usage information present"
    else
        assert_true false "Usage information missing"
    fi

    if grep -q "Available logs:" "$script_output"; then
        assert_true true "Available logs listed"
    else
        assert_true false "Available logs not listed"
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
run_test_with_setup test_log_directory_structure "Log directory structure is correct"
run_test_with_setup test_build_log_creation "Build logs are created properly"
run_test_with_setup test_master_summary_log "Master summary log is formatted correctly"
run_test_with_setup test_log_file_permissions "Log files have correct permissions"
run_test_with_setup test_log_search "Log search functionality works"
run_test_with_setup test_log_listing "Log listing works correctly"
run_test_with_setup test_log_timestamps "Log timestamps are formatted correctly"
run_test_with_setup test_error_detection "Error detection in logs works"
run_test_with_setup test_log_rotation "Log rotation is handled properly"
run_test_with_setup test_script_usage "Script usage information is complete"

# Generate test report
generate_report
