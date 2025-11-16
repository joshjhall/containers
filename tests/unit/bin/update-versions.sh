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
    local test_dir
    test_dir=$(mktemp -d)
    
    # Create mock Dockerfile
    command cat > "$test_dir/Dockerfile" << 'EOF'
ARG PYTHON_VERSION=3.13.0
ARG NODE_VERSION=22.10.0
EOF
    
    # Create mock JSON with updates
    command cat > "$test_dir/test.json" << 'EOF'
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
    output=$(PROJECT_ROOT_OVERRIDE="$test_dir" "$PROJECT_ROOT/bin/update-versions.sh" --dry-run --input test.json 2>&1)
    
    # Check that file wasn't modified
    if grep -q "ARG PYTHON_VERSION=3.13.0" Dockerfile && echo "$output" | grep -q "DRY RUN"; then
        command rm -rf "$test_dir"
        return 0
    else
        command rm -rf "$test_dir"
        return 1
    fi
}

# Test: Actual version update
test_version_update() {
    # Create temporary test directory
    local test_dir
    test_dir=$(mktemp -d)
    
    # Create mock Dockerfile
    command cat > "$test_dir/Dockerfile" << 'EOF'
ARG PYTHON_VERSION=3.13.0
ARG NODE_VERSION=22.10.0
EOF
    
    # Create lib/features directory
    mkdir -p "$test_dir/lib/features"
    
    # Create mock JSON with updates
    command cat > "$test_dir/test.json" << 'EOF'
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
    PROJECT_ROOT_OVERRIDE="$test_dir" "$PROJECT_ROOT/bin/update-versions.sh" --no-commit --no-bump --input test.json >/dev/null 2>&1
    
    # Check that file was modified
    if grep -q "ARG PYTHON_VERSION=3.13.6" Dockerfile; then
        command rm -rf "$test_dir"
        return 0
    else
        command rm -rf "$test_dir"
        return 1
    fi
}

# Test: No updates needed
test_no_updates() {
    # Create temporary test directory
    local test_dir
    test_dir=$(mktemp -d)
    
    # Create mock JSON with no updates
    command cat > "$test_dir/test.json" << 'EOF'
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
    output=$(PROJECT_ROOT_OVERRIDE="$test_dir" "$PROJECT_ROOT/bin/update-versions.sh" --no-bump --input test.json 2>&1)
    
    if echo "$output" | grep -q "All versions are up to date"; then
        command rm -rf "$test_dir"
        return 0
    else
        command rm -rf "$test_dir"
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
    local test_dir
    test_dir=$(mktemp -d)
    
    # Create lib/features directory and mock script
    mkdir -p "$test_dir/lib/features"
    command cat > "$test_dir/lib/features/dev-tools.sh" << 'EOF'
#!/bin/bash
LAZYGIT_VERSION="0.54.1"
DIRENV_VERSION="2.37.1"
EOF
    
    # Create mock JSON with shell script update
    command cat > "$test_dir/test.json" << 'EOF'
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
    PROJECT_ROOT_OVERRIDE="$test_dir" "$PROJECT_ROOT/bin/update-versions.sh" --no-commit --no-bump --input test.json >/dev/null 2>&1
    
    # Check that file was modified
    if grep -q 'LAZYGIT_VERSION="0.54.2"' lib/features/dev-tools.sh; then
        command rm -rf "$test_dir"
        return 0
    else
        command rm -rf "$test_dir"
        return 1
    fi
}

# Test: Java dev tools update
test_java_dev_tools_update() {
    # Create temporary test directory
    local test_dir
    test_dir=$(mktemp -d)
    
    # Create lib/features directory and mock script
    mkdir -p "$test_dir/lib/features"
    command cat > "$test_dir/lib/features/java-dev.sh" << 'EOF'
#!/bin/bash
SPRING_VERSION="3.4.2"
JBANG_VERSION="0.121.0"
    MVND_VERSION="1.0.2"
GJF_VERSION="1.25.2"
EOF
    
    # Create mock JSON with Java tool updates
    command cat > "$test_dir/test.json" << 'EOF'
{
  "tools": [
    {
      "tool": "spring-boot-cli",
      "current": "3.4.2",
      "latest": "3.5.4",
      "file": "java-dev.sh",
      "status": "outdated"
    },
    {
      "tool": "jbang",
      "current": "0.121.0",
      "latest": "0.129.0",
      "file": "java-dev.sh",
      "status": "outdated"
    },
    {
      "tool": "mvnd",
      "current": "1.0.2",
      "latest": "1.0.3",
      "file": "java-dev.sh",
      "status": "outdated"
    },
    {
      "tool": "google-java-format",
      "current": "1.25.2",
      "latest": "1.28.0",
      "file": "java-dev.sh",
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
    PROJECT_ROOT_OVERRIDE="$test_dir" "$PROJECT_ROOT/bin/update-versions.sh" --no-commit --no-bump --input test.json >/dev/null 2>&1
    
    # Check that all Java tools were updated
    local all_updated=true
    if ! grep -q 'SPRING_VERSION="3.5.4"' lib/features/java-dev.sh; then
        all_updated=false
    fi
    if ! grep -q 'JBANG_VERSION="0.129.0"' lib/features/java-dev.sh; then
        all_updated=false
    fi
    if ! grep -q 'MVND_VERSION="1.0.3"' lib/features/java-dev.sh; then
        all_updated=false
    fi
    if ! grep -q 'GJF_VERSION="1.28.0"' lib/features/java-dev.sh; then
        all_updated=false
    fi
    
    command rm -rf "$test_dir"
    
    if [ "$all_updated" = true ]; then
        return 0
    else
        return 1
    fi
}

# Test: duf and entr updates
test_duf_entr_update() {
    # Create temporary test directory
    local test_dir
    test_dir=$(mktemp -d)
    
    # Create lib/features directory and mock script
    mkdir -p "$test_dir/lib/features"
    command cat > "$test_dir/lib/features/dev-tools.sh" << 'EOF'
#!/bin/bash
DUF_VERSION="0.8.0"
ENTR_VERSION="5.5"
EOF
    
    # Create mock JSON with tool updates
    command cat > "$test_dir/test.json" << 'EOF'
{
  "tools": [
    {
      "tool": "duf",
      "current": "0.8.0",
      "latest": "0.8.1",
      "file": "dev-tools.sh",
      "status": "outdated"
    },
    {
      "tool": "entr",
      "current": "5.5",
      "latest": "5.7",
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
    PROJECT_ROOT_OVERRIDE="$test_dir" "$PROJECT_ROOT/bin/update-versions.sh" --no-commit --no-bump --input test.json >/dev/null 2>&1
    
    # Check that both tools were updated
    local all_updated=true
    if ! grep -q 'DUF_VERSION="0.8.1"' lib/features/dev-tools.sh; then
        all_updated=false
    fi
    if ! grep -q 'ENTR_VERSION="5.7"' lib/features/dev-tools.sh; then
        all_updated=false
    fi
    
    command rm -rf "$test_dir"
    
    if [ "$all_updated" = true ]; then
        return 0
    else
        return 1
    fi
}

# Test: Invalid version validation
test_invalid_version_validation() {
    # Create temporary test directory
    local test_dir
    test_dir=$(mktemp -d)
    
    # Create mock Dockerfile
    command cat > "$test_dir/Dockerfile" << 'EOF'
ARG PYTHON_VERSION=3.13.0
ARG NODE_VERSION=22.10.0
ARG GO_VERSION=1.22.3
ARG RUST_VERSION=1.80.0
EOF
    
    # Create mock JSON with invalid versions
    command cat > "$test_dir/test.json" << 'EOF'
{
  "tools": [
    {
      "tool": "Python",
      "current": "3.13.0",
      "latest": "null",
      "file": "Dockerfile",
      "status": "outdated"
    },
    {
      "tool": "Node.js",
      "current": "22.10.0",
      "latest": "",
      "file": "Dockerfile",
      "status": "outdated"
    },
    {
      "tool": "Go",
      "current": "1.22.3",
      "latest": "undefined",
      "file": "Dockerfile",
      "status": "outdated"
    },
    {
      "tool": "Rust",
      "current": "1.80.0",
      "latest": "error",
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
    output=$(PROJECT_ROOT_OVERRIDE="$test_dir" "$PROJECT_ROOT/bin/update-versions.sh" --no-commit --no-bump --input test.json 2>&1)
    
    # Check that invalid versions were rejected and files were not modified
    local success=true
    
    # Check output contains error messages
    if ! echo "$output" | grep -q "Invalid version format"; then
        success=false
    fi
    
    # Check that no invalid versions were written to Dockerfile
    if grep -q "null\|undefined\|error" Dockerfile; then
        success=false
    fi
    
    # Check original versions are still there
    if ! grep -q "ARG PYTHON_VERSION=3.13.0" Dockerfile; then
        success=false
    fi
    if ! grep -q "ARG NODE_VERSION=22.10.0" Dockerfile; then
        success=false
    fi
    if ! grep -q "ARG GO_VERSION=1.22.3" Dockerfile; then
        success=false
    fi
    if ! grep -q "ARG RUST_VERSION=1.80.0" Dockerfile; then
        success=false
    fi
    
    command rm -rf "$test_dir"
    
    if [ "$success" = true ]; then
        return 0
    else
        return 1
    fi
}

# Test: Mixed valid and invalid versions
test_mixed_valid_invalid_versions() {
    # Create temporary test directory
    local test_dir
    test_dir=$(mktemp -d)
    
    # Create mock Dockerfile
    command cat > "$test_dir/Dockerfile" << 'EOF'
ARG PYTHON_VERSION=3.13.0
ARG NODE_VERSION=22.10.0
ARG GO_VERSION=1.22.3
EOF
    
    # Create mock JSON with mixed valid and invalid versions
    command cat > "$test_dir/test.json" << 'EOF'
{
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
      "latest": "null",
      "file": "Dockerfile",
      "status": "outdated"
    },
    {
      "tool": "Go",
      "current": "1.22.3",
      "latest": "1.25.0",
      "file": "Dockerfile",
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
    output=$(PROJECT_ROOT_OVERRIDE="$test_dir" "$PROJECT_ROOT/bin/update-versions.sh" --no-commit --no-bump --input test.json 2>&1)
    
    # Check that valid versions were updated and invalid ones were rejected
    local success=true
    
    # Python should be updated (valid)
    if ! grep -q "ARG PYTHON_VERSION=3.13.6" Dockerfile; then
        success=false
    fi
    
    # Node.js should NOT be updated (invalid)
    if ! grep -q "ARG NODE_VERSION=22.10.0" Dockerfile; then
        success=false
    fi
    
    # Go should be updated (valid)
    if ! grep -q "ARG GO_VERSION=1.25.0" Dockerfile; then
        success=false
    fi
    
    # Check that "null" was not written
    if grep -q "null" Dockerfile; then
        success=false
    fi
    
    command rm -rf "$test_dir"
    
    if [ "$success" = true ]; then
        return 0
    else
        return 1
    fi
}

# Test: Script updates zoxide version in base setup
test_update_zoxide_version() {
    local test_dir="$RESULTS_DIR/test_zoxide_update"
    command rm -rf "$test_dir"
    mkdir -p "$test_dir/lib/base"
    
    # Create test base setup script with old zoxide version
    command cat > "$test_dir/lib/base/setup.sh" <<'EOF'
#!/bin/bash
# Base system setup

echo "=== Installing zoxide ==="
ARCH=$(dpkg --print-architecture)
ZOXIDE_VERSION="0.9.0"
cd /tmp
EOF
    
    # Create mock version check output
    command cat > "$test_dir/test.json" <<'EOF'
{
  "timestamp": "2024-08-13T10:00:00Z",
  "tools": [
    {
      "tool": "zoxide",
      "current": "0.9.0",
      "latest": "0.9.8",
      "file": "setup.sh",
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
    echo 'echo "1.0.1" > VERSION' >> bin/release.sh
    chmod +x bin/release.sh
    echo "1.0.0" > VERSION
    
    # Run update
    PROJECT_ROOT_OVERRIDE="$test_dir" "$PROJECT_ROOT/bin/update-versions.sh" --no-commit --no-bump --input test.json >/dev/null 2>&1
    
    # Check that zoxide was updated
    local updated=false
    if grep -q 'ZOXIDE_VERSION="0.9.8"' lib/base/setup.sh; then
        updated=true
    fi
    
    command rm -rf "$test_dir"
    
    if [ "$updated" = true ]; then
        return 0
    else
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
run_test test_java_dev_tools_update "Updates Java dev tool versions"
run_test test_duf_entr_update "Updates duf and entr versions"
run_test test_update_zoxide_version "Updates zoxide version in base setup"
run_test test_invalid_version_validation "Rejects invalid version formats (null, undefined, error)"
run_test test_mixed_valid_invalid_versions "Updates valid versions while rejecting invalid ones"

# Test removed: kubernetes-checksums.sh no longer exists
# Kubernetes, dev-tools, and golang now use dynamic checksum fetching
# Checksums are fetched at build time from upstream sources

# Test: krew update handler exists
test_krew_update_handler() {
    # Check that update-versions.sh has krew update handling
    if grep -q "krew)" "$PROJECT_ROOT/bin/update-versions.sh"; then
        assert_true true "update-versions.sh has krew update handler"
    else
        assert_true false "update-versions.sh missing krew update handler"
    fi

    # Check that it updates KREW_VERSION in Dockerfile
    if grep -q "ARG KREW_VERSION=" "$PROJECT_ROOT/bin/update-versions.sh"; then
        assert_true true "update-versions.sh updates KREW_VERSION"
    else
        assert_true false "update-versions.sh missing KREW_VERSION update"
    fi
}

# Test: Helm update handler exists
test_helm_update_handler() {
    # Check that update-versions.sh has Helm update handling
    if grep -q "Helm)" "$PROJECT_ROOT/bin/update-versions.sh"; then
        assert_true true "update-versions.sh has Helm update handler"
    else
        assert_true false "update-versions.sh missing Helm update handler"
    fi

    # Check that it updates HELM_VERSION in Dockerfile
    if grep -q "ARG HELM_VERSION=" "$PROJECT_ROOT/bin/update-versions.sh"; then
        assert_true true "update-versions.sh updates HELM_VERSION"
    else
        assert_true false "update-versions.sh missing HELM_VERSION update"
    fi
}

# Test removed - kubernetes-checksums.sh no longer needed (uses dynamic fetching)
run_test test_krew_update_handler "krew update handler exists"
run_test test_helm_update_handler "Helm update handler exists"

# Generate report
generate_report