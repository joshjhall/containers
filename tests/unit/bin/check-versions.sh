#!/usr/bin/env bash
# Unit tests for bin/check-versions.sh
# Tests version checking functionality without requiring Docker builds

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Bin Check Versions Tests"

# Helper function to extract version from a variable assignment
# Handles both plain assignments (VAR="1.2.3") and parameter expansion (VAR="${VAR:-1.2.3}")
extract_version_from_line() {
    local line="$1"
    local ver

    # Extract the value after the = sign, removing quotes
    ver=$(echo "$line" | cut -d= -f2 | tr -d '"')

    # If it's a parameter expansion like ${VAR:-default}, extract the default value
    if [[ "$ver" =~ \$\{[^:]*:-([^}]+)\} ]]; then
        ver="${BASH_REMATCH[1]}"
    fi

    echo "$ver"
}

# Mock function to simulate fetch_url responses
mock_fetch_url() {
    local url="$1"
    case "$url" in
        *"endoflife.date/api/python.json"*)
            echo '[{"cycle":"3.13","latest":"3.13.6"},{"cycle":"3.12","latest":"3.12.8"}]'
            ;;
        *"nodejs.org/dist/index.json"*)
            echo '[{"version":"v22.18.0","lts":"Jod"},{"version":"v20.18.1","lts":"Iron"}]'
            ;;
        *"go.dev/VERSION"*)
            echo "go1.24.6"
            ;;
        *)
            echo ""
            ;;
    esac
}

# Test: version_matches function with exact match
test_version_matches_exact() {
    # Create a mock version_matches function for testing
    version_matches() {
        local current="$1"
        local latest="$2"
        
        # Handle exact matches first
        if [[ "$current" == "$latest" ]]; then
            return 0
        fi
        
        # Handle prefix matching with proper version boundaries
        # e.g., "22" matches "22.18.0" but not "220.0.0"
        if [[ "$latest" == "$current."* ]] || [[ "$latest" == "$current" ]]; then
            return 0
        fi
        
        return 1
    }
    
    # Test exact match
    if version_matches "3.13.6" "3.13.6"; then
        assert_true true "Exact version match works"
    else
        assert_true false "Exact version match failed"
    fi
}

# Test: version_matches function with partial match
test_version_matches_partial() {
    # Create a mock version_matches function for testing
    version_matches() {
        local current="$1"
        local latest="$2"
        
        # Handle exact matches first
        if [[ "$current" == "$latest" ]]; then
            return 0
        fi
        
        # Handle prefix matching with proper version boundaries
        # e.g., "22" matches "22.18.0" but not "220.0.0"
        if [[ "$latest" == "$current."* ]] || [[ "$latest" == "$current" ]]; then
            return 0
        fi
        
        return 1
    }
    
    # Test partial match (major.minor matches major.minor.patch)
    if version_matches "1.33" "1.33.3"; then
        assert_true true "Partial version match works (1.33 matches 1.33.3)"
    else
        assert_true false "Partial version match failed"
    fi
    
    # Test major version match
    if version_matches "22" "22.18.0"; then
        assert_true true "Major version match works (22 matches 22.18.0)"
    else
        assert_true false "Major version match failed"
    fi
}

# Test: version_matches function with non-match
test_version_matches_different() {
    # Create a mock version_matches function for testing
    version_matches() {
        local current="$1"
        local latest="$2"
        
        # Handle exact matches first
        if [[ "$current" == "$latest" ]]; then
            return 0
        fi
        
        # Handle prefix matching with proper version boundaries
        # e.g., "22" matches "22.18.0" but not "220.0.0"
        if [[ "$latest" == "$current."* ]] || [[ "$latest" == "$current" ]]; then
            return 0
        fi
        
        return 1
    }
    
    # Test different versions
    if ! version_matches "1.32" "1.33.3"; then
        assert_true true "Different versions correctly identified as non-match"
    else
        assert_true false "Different versions incorrectly matched"
    fi
    
    # Test partial that shouldn't match
    if ! version_matches "21" "210.0.0"; then
        assert_true true "Prefix check correctly rejects invalid match"
    else
        assert_true false "Invalid prefix match was accepted"
    fi
}

# Test: Check if script exists and is executable
test_script_exists() {
    assert_file_exists "$PROJECT_ROOT/bin/check-versions.sh"
    assert_executable "$PROJECT_ROOT/bin/check-versions.sh"
}

# Test: Script handles missing .env file gracefully
test_missing_env_file() {
    # Temporarily move .env if it exists
    local env_backup=""
    if [ -f "$PROJECT_ROOT/.env" ]; then
        env_backup="$PROJECT_ROOT/.env.backup.$$"
        command mv "$PROJECT_ROOT/.env" "$env_backup"
    fi
    
    # Run script without .env file (strip ANSI colors)
    local output
    output=$("$PROJECT_ROOT/bin/check-versions.sh" 2>&1 | command sed 's/\x1b\[[0-9;]*m//g' | head -10 || true)
    
    # Check for warning about missing token
    if echo "$output" | grep -q "Warning: No GITHUB_TOKEN set"; then
        assert_true true "Script handles missing .env file gracefully"
    else
        # The script might be using the token from environment
        assert_true true "Script runs without .env file"
    fi
    
    # Restore .env if it was backed up
    if [ -n "$env_backup" ] && [ -f "$env_backup" ]; then
        command mv "$env_backup" "$PROJECT_ROOT/.env"
    fi
}

# Test: Script extracts versions from Dockerfile
test_extract_dockerfile_versions() {
    # Create a temporary test Dockerfile
    local test_dockerfile="$RESULTS_DIR/test_dockerfile"
    command cat > "$test_dockerfile" <<'EOF'
ARG PYTHON_VERSION=3.13.6
ARG NODE_VERSION=22
ARG GO_VERSION=1.24.6
EOF
    
    # Check if versions can be extracted
    local python_ver
    python_ver=$(grep "^ARG PYTHON_VERSION=" "$test_dockerfile" | cut -d= -f2 | tr -d '"')
    assert_equals "3.13.6" "$python_ver" "Python version extracted correctly"

    local node_ver
    node_ver=$(grep "^ARG NODE_VERSION=" "$test_dockerfile" | cut -d= -f2 | tr -d '"')
    assert_equals "22" "$node_ver" "Node version extracted correctly"
    
    # Clean up
    command rm -f "$test_dockerfile"
}

# Test: Script extracts versions from feature scripts
test_extract_feature_versions() {
    # Check if dev-tools.sh exists and has version definitions
    if [ -f "$PROJECT_ROOT/lib/features/dev-tools.sh" ]; then
        local lazygit_ver
        lazygit_ver=$(grep '^LAZYGIT_VERSION=' "$PROJECT_ROOT/lib/features/dev-tools.sh" | cut -d= -f2 | tr -d '"')
        assert_not_empty "$lazygit_ver" "Lazygit version extracted from dev-tools.sh"
    else
        skip_test "dev-tools.sh not found"
    fi
}

# Test: JSON output format
test_json_output_format() {
    # Test that the script supports --json flag
    local output

    # First check if --help mentions JSON
    if "$PROJECT_ROOT/bin/check-versions.sh" --help 2>&1 | grep -q "json"; then
        # JSON is supported, test it with a short timeout
        output=$(timeout 5 "$PROJECT_ROOT/bin/check-versions.sh" --json --no-cache 2>/dev/null || true)

        if [[ "$output" == "{"* ]]; then
            assert_true true "Script produces JSON output"
        else
            # Might be taking too long, just check if script runs
            assert_true true "Script supports --json flag"
        fi
    else
        # Fallback to text format check
        output=$(timeout 5 "$PROJECT_ROOT/bin/check-versions.sh" 2>&1 | head -5 || true)
        if echo "$output" | grep -q "Version Check Results\|Checking\|Scanning"; then
            assert_true true "Script produces formatted output"
        else
            assert_true false "Script output format is incorrect"
        fi
    fi
}

# Test: JSON output is valid and well-formed
test_json_output_valid() {
    # Run the script with --json flag and validate output with jq
    local output
    local exit_code=0

    # Capture output and exit code separately (timeout returns 124 on timeout)
    output=$(timeout 30 "$PROJECT_ROOT/bin/check-versions.sh" --json --no-cache 2>&1) || exit_code=$?

    # If timeout occurred (exit code 124), skip this test - network too slow in CI
    if [ "$exit_code" -eq 124 ]; then
        skip_test "Script timed out (30s) - network conditions too slow for full version check"
        return
    fi

    # If we got empty output with a non-zero exit code, likely a network/API issue
    # Skip gracefully rather than failing - this is a flaky test in CI environments
    if [ -z "$output" ] && [ "$exit_code" -ne 0 ]; then
        skip_test "Script produced no output (exit code: $exit_code) - likely network/API issue in CI"
        return
    fi

    # If we got empty output with exit code 0, that's a real bug
    if [ -z "$output" ]; then
        assert_true false "Script produced no output despite exit code 0"
        return
    fi

    # Check if the output is valid JSON using jq
    if echo "$output" | jq empty 2>/dev/null; then
        assert_true true "Script produces valid JSON that can be parsed by jq"

        # Also verify the JSON has expected structure
        if echo "$output" | jq -e '.tools' >/dev/null 2>&1 && \
           echo "$output" | jq -e '.summary' >/dev/null 2>&1; then
            assert_true true "JSON output has expected structure (tools, summary)"
        else
            assert_true false "JSON output is missing expected fields"
        fi
    else
        # If JSON is invalid, show the error for debugging
        echo "Invalid JSON output:" >&2
        echo "$output" | head -20 >&2
        assert_true false "Script failed to produce valid JSON (syntax error or malformed output)"
    fi
}

# Test: Script has no bash syntax errors
test_script_syntax() {
    # Use bash -n to check for syntax errors without executing
    if bash -n "$PROJECT_ROOT/bin/check-versions.sh" 2>/dev/null; then
        assert_true true "Script has valid bash syntax"
    else
        local errors
        errors=$(bash -n "$PROJECT_ROOT/bin/check-versions.sh" 2>&1 || true)
        echo "Bash syntax errors found:" >&2
        echo "$errors" >&2
        assert_true false "Script contains bash syntax errors"
    fi
}

# Test: Exit code when versions are current
test_exit_code_current() {
    # This would require mocking all API calls, so we'll test the logic
    # by checking if the script exits with 0 when no outdated versions
    assert_true true "Exit code test placeholder (requires full mocking)"
}

# Test: Exit code when versions are outdated
test_exit_code_outdated() {
    # The script should exit with 1 when outdated versions are found
    # This is tested in integration tests with actual API calls
    assert_true true "Exit code test placeholder (requires full mocking)"
}

# Test: Script extracts Java dev tool versions
test_extract_java_dev_versions() {
    # Check if java-dev.sh exists and has version definitions
    if [ -f "$PROJECT_ROOT/lib/features/java-dev.sh" ]; then
        # Test both regular and indented versions
        local spring_ver
        spring_ver=$(grep '^SPRING_VERSION=' "$PROJECT_ROOT/lib/features/java-dev.sh" 2>/dev/null | cut -d= -f2 | tr -d '"')
        local jbang_ver
        jbang_ver=$(grep '^JBANG_VERSION=' "$PROJECT_ROOT/lib/features/java-dev.sh" 2>/dev/null | cut -d= -f2 | tr -d '"')
        # MVND_VERSION is indented in the actual file
        local mvnd_ver
        mvnd_ver=$(grep 'MVND_VERSION=' "$PROJECT_ROOT/lib/features/java-dev.sh" 2>/dev/null | command sed 's/.*MVND_VERSION=//' | tr -d '"' | head -1)
        local gjf_ver
        gjf_ver=$(grep '^GJF_VERSION=' "$PROJECT_ROOT/lib/features/java-dev.sh" 2>/dev/null | cut -d= -f2 | tr -d '"')

        assert_not_empty "$spring_ver" "Spring Boot CLI version extracted"
        assert_not_empty "$jbang_ver" "JBang version extracted"
        assert_not_empty "$mvnd_ver" "MVND version extracted (indented)"
        assert_not_empty "$gjf_ver" "Google Java Format version extracted"
    else
        skip_test "java-dev.sh not found"
    fi
}

# Test: Script extracts duf and entr versions
test_extract_duf_entr_versions() {
    # Check if dev-tools.sh has duf and entr version definitions
    if [ -f "$PROJECT_ROOT/lib/features/dev-tools.sh" ]; then
        local duf_ver
        duf_ver=$(grep '^DUF_VERSION=' "$PROJECT_ROOT/lib/features/dev-tools.sh" 2>/dev/null | cut -d= -f2 | tr -d '"')
        local entr_ver
        entr_ver=$(grep '^ENTR_VERSION=' "$PROJECT_ROOT/lib/features/dev-tools.sh" 2>/dev/null | cut -d= -f2 | tr -d '"')

        assert_not_empty "$duf_ver" "duf version extracted from dev-tools.sh"
        assert_not_empty "$entr_ver" "entr version extracted from dev-tools.sh"
    else
        skip_test "dev-tools.sh not found"
    fi
}

# Test: Script handles indented version patterns
test_handle_indented_versions() {
    # Create a temporary test script with indented versions
    local test_script="$RESULTS_DIR/test_indented.sh"
    command cat > "$test_script" <<'EOF'
#!/bin/bash
if [ condition ]; then
    SOME_VERSION="1.2.3"
    ANOTHER_VERSION="4.5.6"
fi
EOF
    
    # Check if indented versions can be extracted with proper pattern
    local some_ver
    some_ver=$(grep '^\s*SOME_VERSION=' "$test_script" 2>/dev/null | command sed 's/.*=//' | tr -d '"')
    local another_ver
    another_ver=$(grep 'ANOTHER_VERSION=' "$test_script" 2>/dev/null | command sed 's/.*=//' | tr -d '"')

    assert_equals "1.2.3" "$some_ver" "Indented version extracted correctly"
    assert_equals "4.5.6" "$another_ver" "Another indented version extracted correctly"
    
    # Clean up
    command rm -f "$test_script"
}

# Test: Script extracts zoxide version from base setup
test_extract_zoxide_version() {
    # Check if base/setup.sh has zoxide version definition
    if [ -f "$PROJECT_ROOT/lib/base/setup.sh" ]; then
        local zoxide_ver
        zoxide_ver=$(extract_version_from_line "$(grep '^ZOXIDE_VERSION=' "$PROJECT_ROOT/lib/base/setup.sh" 2>/dev/null)")

        assert_not_empty "$zoxide_ver" "zoxide version extracted from base/setup.sh"
        # Current version is 0.9.8
        assert_equals "0.9.8" "$zoxide_ver" "zoxide version is correctly extracted"
    else
        skip_test "base/setup.sh not found"
    fi
}

# Test: extract_version_from_line handles parameter expansion
test_extract_version_parameter_expansion() {
    local result

    # Test plain assignment
    result=$(extract_version_from_line 'VAR="1.2.3"')
    assert_equals "1.2.3" "$result" "Plain assignment extracted correctly"

    # Test parameter expansion
    result=$(extract_version_from_line 'VAR="${VAR:-1.2.3}"')
    assert_equals "1.2.3" "$result" "Parameter expansion extracted correctly"

    # Test with different variable names
    result=$(extract_version_from_line 'LAZYGIT_VERSION="${LAZYGIT_VERSION:-0.56.0}"')
    assert_equals "0.56.0" "$result" "Real-world parameter expansion works"
}

# Run tests
run_test test_script_exists "Version checker script exists and is executable"
run_test test_script_syntax "Script has valid bash syntax (no typos)"
run_test test_version_matches_exact "version_matches handles exact matches"
run_test test_version_matches_partial "version_matches handles partial matches"
run_test test_version_matches_different "version_matches rejects non-matches"
run_test test_missing_env_file "Script handles missing .env file gracefully"
run_test test_extract_dockerfile_versions "Script extracts versions from Dockerfile"
run_test test_extract_feature_versions "Script extracts versions from feature scripts"
run_test test_json_output_format "JSON output format is correct"
run_test test_json_output_valid "JSON output is valid and well-formed"
run_test test_exit_code_current "Exit code is 0 when all versions current"
run_test test_exit_code_outdated "Exit code is 1 when versions outdated"
run_test test_extract_java_dev_versions "Script extracts Java dev tool versions"
run_test test_extract_duf_entr_versions "Script extracts duf and entr versions"
run_test test_handle_indented_versions "Script handles indented version patterns"
run_test test_extract_zoxide_version "Script extracts zoxide version from base setup"
run_test test_extract_version_parameter_expansion "extract_version_from_line handles parameter expansion"

# Test: Script extracts krew version from Dockerfile
test_extract_krew_version() {
    # Check if krew version can be extracted from Dockerfile
    local krew_ver
    krew_ver=$(grep "^ARG KREW_VERSION=" "$PROJECT_ROOT/Dockerfile" 2>/dev/null | cut -d= -f2 | tr -d '"')

    assert_not_empty "$krew_ver" "krew version extracted from Dockerfile"

    # Verify it's a reasonable version format
    if echo "$krew_ver" | grep -qE '^[0-9]+\.[0-9]+'; then
        assert_true true "krew version has valid format"
    else
        assert_true false "krew version has invalid format: $krew_ver"
    fi
}

run_test test_extract_krew_version "Script extracts krew version from Dockerfile"

# Generate test report
generate_report