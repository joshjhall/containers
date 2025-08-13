#!/usr/bin/env bash
# Unit tests for bin/update-versions.sh

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Update Versions Tests"

# Test: Help output
test_help_output() {
    output=$("$PROJECT_ROOT/bin/update-versions.sh" --help 2>&1 || true)
    
    if echo "$output" | grep -q "Usage:"; then
        return 0
    else
        return 1
    fi
}

# Test: Dry run mode
test_dry_run_mode() {
    # Create temporary test directory
    local test_dir=$(mktemp -d)
    
    # Create mock Dockerfile
    cat > "$test_dir/Dockerfile" << 'EOF'
ARG PYTHON_VERSION=3.13.0
ARG NODE_VERSION=22.10.0
EOF
    
    # Create mock JSON with updates
    cat > "$test_dir/test.json" << 'EOF'
{
  "tools": [
    {
      "tool": "Python",
      "current": "3.13.0",
      "latest": "3.13.6",
      "file": "Dockerfile",
      "status": "outdated"
    }
  ]
}
EOF
    
    # Run in dry run mode
    cd "$test_dir"
    output=$("$PROJECT_ROOT/bin/update-versions.sh" --dry-run --input test.json 2>&1)
    
    # Check that file wasn't modified
    if grep -q "ARG PYTHON_VERSION=3.13.0" Dockerfile && echo "$output" | grep -q "DRY RUN"; then
        rm -rf "$test_dir"
        return 0
    else
        rm -rf "$test_dir"
        return 1
    fi
}

# Test: Actual version update
test_version_update() {
    # Create temporary test directory
    local test_dir=$(mktemp -d)
    
    # Create mock Dockerfile
    cat > "$test_dir/Dockerfile" << 'EOF'
ARG PYTHON_VERSION=3.13.0
ARG NODE_VERSION=22.10.0
EOF
    
    # Create lib/features directory
    mkdir -p "$test_dir/lib/features"
    
    # Create mock JSON with updates
    cat > "$test_dir/test.json" << 'EOF'
{
  "tools": [
    {
      "tool": "Python",
      "current": "3.13.0",
      "latest": "3.13.6",
      "file": "Dockerfile",
      "status": "outdated"
    }
  ]
}
EOF
    
    # Initialize git repo (required for commits)
    cd "$test_dir"
    git init --quiet
    git config user.email "test@example.com"
    git config user.name "Test User"
    git add -A
    git commit -m "Initial" --quiet
    
    # Create mock release script
    mkdir -p bin
    echo '#!/bin/bash' > bin/release.sh
    echo 'echo "1.4.1" > VERSION' >> bin/release.sh
    chmod +x bin/release.sh
    echo "1.4.0" > VERSION
    
    # Run update with --no-commit to avoid git operations
    "$PROJECT_ROOT/bin/update-versions.sh" --no-commit --no-bump --input test.json >/dev/null 2>&1
    
    # Check that file was modified
    if grep -q "ARG PYTHON_VERSION=3.13.6" Dockerfile; then
        rm -rf "$test_dir"
        return 0
    else
        rm -rf "$test_dir"
        return 1
    fi
}

# Test: No updates needed
test_no_updates() {
    # Create temporary test directory
    local test_dir=$(mktemp -d)
    
    # Create mock JSON with no updates
    cat > "$test_dir/test.json" << 'EOF'
{
  "tools": [
    {
      "tool": "Python",
      "current": "3.13.6",
      "latest": "3.13.6",
      "file": "Dockerfile",
      "status": "current"
    }
  ]
}
EOF
    
    cd "$test_dir"
    output=$("$PROJECT_ROOT/bin/update-versions.sh" --input test.json 2>&1)
    
    if echo "$output" | grep -q "All versions are up to date"; then
        rm -rf "$test_dir"
        return 0
    else
        rm -rf "$test_dir"
        return 1
    fi
}

# Test: Invalid input file
test_invalid_input() {
    output=$("$PROJECT_ROOT/bin/update-versions.sh" --input /nonexistent/file.json 2>&1 || true)
    
    if echo "$output" | grep -q "Error: Input file not found"; then
        return 0
    else
        return 1
    fi
}

# Test: Shell script updates
test_shell_script_update() {
    # Create temporary test directory
    local test_dir=$(mktemp -d)
    
    # Create lib/features directory and mock script
    mkdir -p "$test_dir/lib/features"
    cat > "$test_dir/lib/features/dev-tools.sh" << 'EOF'
#!/bin/bash
LAZYGIT_VERSION="0.54.1"
DIRENV_VERSION="2.37.1"
EOF
    
    # Create mock JSON with shell script update
    cat > "$test_dir/test.json" << 'EOF'
{
  "tools": [
    {
      "tool": "lazygit",
      "current": "0.54.1",
      "latest": "0.54.2",
      "file": "dev-tools.sh",
      "status": "outdated"
    }
  ]
}
EOF
    
    # Initialize git repo
    cd "$test_dir"
    git init --quiet
    git config user.email "test@example.com"
    git config user.name "Test User"
    git add -A
    git commit -m "Initial" --quiet
    
    # Create mock release script
    mkdir -p bin
    echo '#!/bin/bash' > bin/release.sh
    echo 'echo "1.4.1" > VERSION' >> bin/release.sh
    chmod +x bin/release.sh
    echo "1.4.0" > VERSION
    
    # Run update
    "$PROJECT_ROOT/bin/update-versions.sh" --no-commit --no-bump --input test.json >/dev/null 2>&1
    
    # Check that file was modified
    if grep -q 'LAZYGIT_VERSION="0.54.2"' lib/features/dev-tools.sh; then
        rm -rf "$test_dir"
        return 0
    else
        rm -rf "$test_dir"
        return 1
    fi
}

# Run tests
run_test test_help_output "Help output displays correctly"
run_test test_dry_run_mode "Dry run mode doesn't modify files"
run_test test_version_update "Version updates are applied"
run_test test_no_updates "Handles no updates needed"
run_test test_invalid_input "Handles invalid input file"
run_test test_shell_script_update "Updates shell script versions"

# Generate report
generate_report