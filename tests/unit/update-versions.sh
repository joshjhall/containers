#!/usr/bin/env bash
# Unit tests for bin/update-versions.sh

# Source test framework
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

# Test setup
setup_test_environment() {
    # Create temporary directory for test files
    TEST_DIR=$(mktemp -d)
    export TEST_PROJECT_ROOT="$TEST_DIR"
    
    # Create mock Dockerfile
    cat > "$TEST_DIR/Dockerfile" << 'EOF'
# Test Dockerfile
ARG PYTHON_VERSION=3.13.0
ARG NODE_VERSION=22.10.0
ARG GO_VERSION=1.24.6
ARG RUST_VERSION=1.89.0
ARG RUBY_VERSION=3.4.5
ARG JAVA_VERSION=21
ARG R_VERSION=4.5.1
ARG KUBECTL_VERSION=1.33
ARG K9S_VERSION=0.50.9
ARG TERRAGRUNT_VERSION=0.84.1
ARG TERRAFORM_DOCS_VERSION=0.20.0
EOF
    
    # Create mock feature scripts directory
    mkdir -p "$TEST_DIR/lib/features"
    
    # Create mock dev-tools.sh
    cat > "$TEST_DIR/lib/features/dev-tools.sh" << 'EOF'
#!/bin/bash
LAZYGIT_VERSION="0.54.1"
DIRENV_VERSION="2.37.1"
ACT_VERSION="0.2.80"
DELTA_VERSION="0.18.2"
GLAB_VERSION="1.65.0"
MKCERT_VERSION="1.4.4"
EOF
    
    # Create mock docker.sh
    cat > "$TEST_DIR/lib/features/docker.sh" << 'EOF'
#!/bin/bash
DIVE_VERSION="0.13.1"
LAZYDOCKER_VERSION="0.24.1"
EOF
    
    # Create mock version check output
    cat > "$TEST_DIR/test-versions.json" << 'EOF'
{
  "timestamp": "2025-08-12T22:00:00-05:00",
  "tools": [
    {
      "tool": "Python",
      "current": "3.13.0",
      "latest": "3.13.6",
      "file": "Dockerfile",
      "status": "outdated"
    },
    {
      "tool": "Node.js",
      "current": "22.10.0",
      "latest": "22.18.0",
      "file": "Dockerfile",
      "status": "outdated"
    },
    {
      "tool": "Go",
      "current": "1.24.6",
      "latest": "1.25.0",
      "file": "Dockerfile",
      "status": "outdated"
    },
    {
      "tool": "lazygit",
      "current": "0.54.1",
      "latest": "0.54.2",
      "file": "dev-tools.sh",
      "status": "outdated"
    },
    {
      "tool": "Rust",
      "current": "1.89.0",
      "latest": "1.89.0",
      "file": "Dockerfile",
      "status": "current"
    }
  ],
  "summary": {
    "total": 5,
    "current": 1,
    "outdated": 4
  }
}
EOF
    
    # Create mock release.sh script
    mkdir -p "$TEST_DIR/bin"
    cat > "$TEST_DIR/bin/release.sh" << 'EOF'
#!/bin/bash
echo "Mock release script: $1"
if [ "$1" = "patch" ]; then
    # Simulate updating VERSION file
    echo "1.4.1" > "$TEST_DIR/VERSION"
fi
exit 0
EOF
    chmod +x "$TEST_DIR/bin/release.sh"
    
    # Create VERSION file
    echo "1.4.0" > "$TEST_DIR/VERSION"
    
    # Initialize git repo for testing commits
    cd "$TEST_DIR"
    git init --quiet
    git config user.email "test@example.com"
    git config user.name "Test User"
    git add -A
    git commit -m "Initial test commit" --quiet
    cd - > /dev/null
}

cleanup_test_environment() {
    if [ -n "$TEST_DIR" ] && [ -d "$TEST_DIR" ]; then
        rm -rf "$TEST_DIR"
    fi
}

# Test dry run mode
test_dry_run_mode() {
    test_start "Dry run mode"
    
    setup_test_environment
    
    # Run update script in dry run mode
    cd "$TEST_DIR"
    output=$("$CONTAINERS_ROOT/bin/update-versions.sh" --dry-run --input test-versions.json 2>&1)
    result=$?
    
    # Check that no files were modified
    if grep -q "ARG PYTHON_VERSION=3.13.0" Dockerfile; then
        test_pass "Dockerfile not modified in dry run"
    else
        test_fail "Dockerfile was modified in dry run mode"
    fi
    
    if grep -q 'LAZYGIT_VERSION="0.54.1"' lib/features/dev-tools.sh; then
        test_pass "Shell script not modified in dry run"
    else
        test_fail "Shell script was modified in dry run mode"
    fi
    
    if echo "$output" | grep -q "Dry run complete"; then
        test_pass "Dry run message displayed"
    else
        test_fail "Dry run message not found"
    fi
    
    cleanup_test_environment
}

# Test actual updates
test_version_updates() {
    test_start "Version updates"
    
    setup_test_environment
    
    # Run update script with --no-commit to avoid git operations
    cd "$TEST_DIR"
    output=$("$CONTAINERS_ROOT/bin/update-versions.sh" --no-commit --no-bump --input test-versions.json 2>&1)
    result=$?
    
    # Check Dockerfile updates
    if grep -q "ARG PYTHON_VERSION=3.13.6" Dockerfile; then
        test_pass "Python version updated"
    else
        test_fail "Python version not updated"
    fi
    
    if grep -q "ARG NODE_VERSION=22.18.0" Dockerfile; then
        test_pass "Node.js version updated"
    else
        test_fail "Node.js version not updated"
    fi
    
    if grep -q "ARG GO_VERSION=1.25.0" Dockerfile; then
        test_pass "Go version updated"
    else
        test_fail "Go version not updated"
    fi
    
    # Check that current versions weren't changed
    if grep -q "ARG RUST_VERSION=1.89.0" Dockerfile; then
        test_pass "Rust version unchanged (was current)"
    else
        test_fail "Rust version incorrectly modified"
    fi
    
    # Check shell script updates
    if grep -q 'LAZYGIT_VERSION="0.54.2"' lib/features/dev-tools.sh; then
        test_pass "lazygit version updated"
    else
        test_fail "lazygit version not updated"
    fi
    
    cleanup_test_environment
}

# Test no updates needed
test_no_updates_needed() {
    test_start "No updates needed"
    
    setup_test_environment
    
    # Create JSON with all current versions
    cat > "$TEST_DIR/current-versions.json" << 'EOF'
{
  "timestamp": "2025-08-12T22:00:00-05:00",
  "tools": [
    {
      "tool": "Python",
      "current": "3.13.6",
      "latest": "3.13.6",
      "file": "Dockerfile",
      "status": "current"
    }
  ],
  "summary": {
    "total": 1,
    "current": 1,
    "outdated": 0
  }
}
EOF
    
    cd "$TEST_DIR"
    output=$("$CONTAINERS_ROOT/bin/update-versions.sh" --input current-versions.json 2>&1)
    result=$?
    
    if echo "$output" | grep -q "All versions are up to date"; then
        test_pass "Correct message for no updates"
    else
        test_fail "Wrong message when no updates needed"
    fi
    
    cleanup_test_environment
}

# Test commit creation
test_commit_creation() {
    test_start "Commit creation"
    
    setup_test_environment
    
    cd "$TEST_DIR"
    
    # Run with commits but no version bump
    "$CONTAINERS_ROOT/bin/update-versions.sh" --no-bump --input test-versions.json > /dev/null 2>&1
    
    # Check if commit was created
    commit_count=$(git rev-list --count HEAD)
    if [ "$commit_count" -eq 2 ]; then
        test_pass "Commit created for updates"
    else
        test_fail "Expected 2 commits, found $commit_count"
    fi
    
    # Check commit message
    commit_msg=$(git log -1 --pretty=%B)
    if echo "$commit_msg" | grep -q "chore: Update dependency versions"; then
        test_pass "Correct commit message prefix"
    else
        test_fail "Incorrect commit message"
    fi
    
    if echo "$commit_msg" | grep -q "Python: 3.13.0 → 3.13.6"; then
        test_pass "Commit message includes version details"
    else
        test_fail "Commit message missing version details"
    fi
    
    cleanup_test_environment
}

# Test version bump
test_version_bump() {
    test_start "Version bump"
    
    setup_test_environment
    
    cd "$TEST_DIR"
    
    # Run with version bump
    "$CONTAINERS_ROOT/bin/update-versions.sh" --input test-versions.json > /dev/null 2>&1
    
    # Check if VERSION file was updated
    if grep -q "1.4.1" VERSION; then
        test_pass "VERSION file bumped to patch version"
    else
        test_fail "VERSION file not bumped"
    fi
    
    # Check for two commits (update + bump)
    commit_count=$(git rev-list --count HEAD)
    if [ "$commit_count" -eq 3 ]; then
        test_pass "Two commits created (update + bump)"
    else
        test_fail "Expected 3 total commits, found $commit_count"
    fi
    
    cleanup_test_environment
}

# Test invalid input file
test_invalid_input() {
    test_start "Invalid input handling"
    
    setup_test_environment
    
    cd "$TEST_DIR"
    output=$("$CONTAINERS_ROOT/bin/update-versions.sh" --input nonexistent.json 2>&1)
    result=$?
    
    if [ "$result" -ne 0 ]; then
        test_pass "Non-zero exit code for missing file"
    else
        test_fail "Should have failed with missing file"
    fi
    
    if echo "$output" | grep -q "Error: Input file not found"; then
        test_pass "Error message for missing file"
    else
        test_fail "No error message for missing file"
    fi
    
    cleanup_test_environment
}

# Test unknown tool handling
test_unknown_tool() {
    test_start "Unknown tool handling"
    
    setup_test_environment
    
    # Create JSON with unknown tool
    cat > "$TEST_DIR/unknown-tool.json" << 'EOF'
{
  "timestamp": "2025-08-12T22:00:00-05:00",
  "tools": [
    {
      "tool": "UnknownTool",
      "current": "1.0.0",
      "latest": "2.0.0",
      "file": "Dockerfile",
      "status": "outdated"
    }
  ]
}
EOF
    
    cd "$TEST_DIR"
    output=$("$CONTAINERS_ROOT/bin/update-versions.sh" --no-commit --input unknown-tool.json 2>&1)
    
    if echo "$output" | grep -q "Warning: Unknown"; then
        test_pass "Warning shown for unknown tool"
    else
        test_fail "No warning for unknown tool"
    fi
    
    cleanup_test_environment
}

# Test help output
test_help_output() {
    test_start "Help output"
    
    output=$("$CONTAINERS_ROOT/bin/update-versions.sh" --help 2>&1)
    result=$?
    
    if [ "$result" -eq 0 ]; then
        test_pass "Help exits with 0"
    else
        test_fail "Help should exit with 0"
    fi
    
    if echo "$output" | grep -q "Usage:"; then
        test_pass "Help shows usage"
    else
        test_fail "Help missing usage"
    fi
    
    if echo "$output" | grep -q -- "--dry-run"; then
        test_pass "Help documents --dry-run"
    else
        test_fail "Help missing --dry-run"
    fi
}

# Run all tests
run_test_suite "update-versions" \
    test_help_output \
    test_dry_run_mode \
    test_version_updates \
    test_no_updates_needed \
    test_commit_creation \
    test_version_bump \
    test_invalid_input \
    test_unknown_tool