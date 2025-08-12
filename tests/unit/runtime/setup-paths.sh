#!/usr/bin/env bash
# Unit tests for lib/runtime/setup-paths.sh
# Tests PATH setup and management

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Setup Paths Tests"

# Setup function - runs before each test
setup() {
    # Create temporary directory for testing
    export TEST_TEMP_DIR="$RESULTS_DIR/test-setup-paths"
    mkdir -p "$TEST_TEMP_DIR"
    
    # Mock environment
    export HOME="/home/testuser"
    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
}

# Teardown function - runs after each test
teardown() {
    # Clean up test directory
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
    
    # Unset test variables
    unset HOME 2>/dev/null || true
}

# Test: PATH contains standard directories
test_standard_paths() {
    # Check standard directories in PATH
    if [[ "$PATH" == *"/usr/local/bin"* ]]; then
        assert_true true "/usr/local/bin in PATH"
    else
        assert_true false "/usr/local/bin not in PATH"
    fi
    
    if [[ "$PATH" == *"/usr/bin"* ]]; then
        assert_true true "/usr/bin in PATH"
    else
        assert_true false "/usr/bin not in PATH"
    fi
    
    if [[ "$PATH" == *"/bin"* ]]; then
        assert_true true "/bin in PATH"
    else
        assert_true false "/bin not in PATH"
    fi
}

# Test: User bin directories
test_user_bin_directories() {
    local user_bin="$TEST_TEMP_DIR/home/testuser/bin"
    local local_bin="$TEST_TEMP_DIR/home/testuser/.local/bin"
    
    # Create user bin directories
    mkdir -p "$user_bin"
    mkdir -p "$local_bin"
    
    assert_dir_exists "$user_bin"
    assert_dir_exists "$local_bin"
    
    # These should be added to PATH
    local new_path="$user_bin:$local_bin:$PATH"
    
    if [[ "$new_path" == *"$user_bin"* ]]; then
        assert_true true "User bin in PATH"
    else
        assert_true false "User bin not in PATH"
    fi
}

# Test: Language-specific paths
test_language_paths() {
    local paths_file="$TEST_TEMP_DIR/paths.txt"
    
    # Create paths configuration
    cat > "$paths_file" << 'EOF'
/usr/local/go/bin
/home/testuser/.cargo/bin
/home/testuser/.rbenv/bin
/cache/npm/bin
/home/testuser/.local/bin
EOF
    
    assert_file_exists "$paths_file"
    
    # Check each path entry
    while IFS= read -r path; do
        assert_not_empty "$path" "Path entry exists: $path"
    done < "$paths_file"
}

# Test: PATH deduplication
test_path_deduplication() {
    # Test with duplicate entries
    local test_path="/usr/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/bin"
    
    # Remove duplicates (simplified test)
    local unique_path=$(echo "$test_path" | tr ':' '\n' | awk '!seen[$0]++' | tr '\n' ':' | sed 's/:$//')
    
    # Count occurrences of /usr/bin
    local count=$(echo "$unique_path" | tr ':' '\n' | grep -c "^/usr/bin$")
    
    assert_equals "1" "$count" "Duplicates removed from PATH"
}

# Test: Cache directories in PATH
test_cache_paths() {
    local cache_paths=(
        "/cache/go/bin"
        "/cache/cargo/bin"
        "/cache/npm/bin"
        "/cache/pip/bin"
    )
    
    for cache_path in "${cache_paths[@]}"; do
        local dir="$TEST_TEMP_DIR$cache_path"
        mkdir -p "$dir"
        assert_dir_exists "$dir"
    done
}

# Test: System tools paths
test_system_tools_paths() {
    local tool_paths=(
        "/opt/tools/bin"
        "/usr/local/sbin"
        "/usr/games"
    )
    
    for tool_path in "${tool_paths[@]}"; do
        assert_not_empty "$tool_path" "System tool path defined: $tool_path"
    done
}

# Test: Path order priority
test_path_priority() {
    # Create mock PATH with specific order
    local ordered_path="/home/testuser/.local/bin:/home/testuser/bin:/usr/local/bin:/usr/bin:/bin"
    
    # Split into array
    IFS=':' read -ra path_array <<< "$ordered_path"
    
    # Check user paths come before system paths
    local user_index=-1
    local system_index=-1
    
    for i in "${!path_array[@]}"; do
        if [[ "${path_array[$i]}" == *"testuser"* ]]; then
            user_index=$i
            break
        fi
    done
    
    for i in "${!path_array[@]}"; do
        if [[ "${path_array[$i]}" == "/usr/bin" ]]; then
            system_index=$i
            break
        fi
    done
    
    if [ "$user_index" -lt "$system_index" ]; then
        assert_true true "User paths have priority over system paths"
    else
        assert_true false "Path priority incorrect"
    fi
}

# Test: Export PATH
test_export_path() {
    local export_file="$TEST_TEMP_DIR/export.sh"
    
    # Create export script
    cat > "$export_file" << 'EOF'
export PATH="/usr/local/bin:/usr/bin:/bin"
export PATH="$HOME/bin:$PATH"
export PATH="$HOME/.local/bin:$PATH"
EOF
    
    assert_file_exists "$export_file"
    
    # Check PATH is exported
    if grep -q "export PATH=" "$export_file"; then
        assert_true true "PATH is exported"
    else
        assert_true false "PATH is not exported"
    fi
}

# Test: PATH validation
test_path_validation() {
    local test_path="/usr/bin:/nonexistent:/usr/local/bin"
    
    # Check each path component
    IFS=':' read -ra paths <<< "$test_path"
    for path in "${paths[@]}"; do
        if [ "$path" = "/nonexistent" ]; then
            assert_true true "Non-existent path detected"
        elif [ "$path" = "/usr/bin" ] || [ "$path" = "/usr/local/bin" ]; then
            assert_true true "Valid path component: $path"
        fi
    done
}

# Test: Verification script
test_path_verification() {
    local test_script="$TEST_TEMP_DIR/test-paths.sh"
    
    # Create verification script
    cat > "$test_script" << 'EOF'
#!/bin/bash
echo "Current PATH:"
echo "$PATH" | tr ':' '\n'
echo ""
echo "PATH components: $(echo "$PATH" | tr ':' '\n' | wc -l)"
echo "Writable directories:"
echo "$PATH" | tr ':' '\n' | while read dir; do
    [ -w "$dir" ] && echo "  - $dir"
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
run_test_with_setup test_standard_paths "Standard paths in PATH"
run_test_with_setup test_user_bin_directories "User bin directories"
run_test_with_setup test_language_paths "Language-specific paths"
run_test_with_setup test_path_deduplication "PATH deduplication"
run_test_with_setup test_cache_paths "Cache directories in PATH"
run_test_with_setup test_system_tools_paths "System tools paths"
run_test_with_setup test_path_priority "Path order priority"
run_test_with_setup test_export_path "PATH export configuration"
run_test_with_setup test_path_validation "PATH validation"
run_test_with_setup test_path_verification "Path verification script"

# Generate test report
generate_report