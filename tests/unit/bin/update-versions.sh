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

    if echo "$output" | command grep -q "Usage:"; then
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
    command cat >"$test_dir/Dockerfile" <<'EOF'
ARG PYTHON_VERSION=3.13.0
ARG NODE_VERSION=22.10.0
EOF

    # Create mock JSON with updates
    command cat >"$test_dir/test.json" <<'EOF'
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
    if command grep -q "ARG PYTHON_VERSION=3.13.0" Dockerfile && echo "$output" | command grep -q "DRY RUN"; then
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
    command cat >"$test_dir/Dockerfile" <<'EOF'
ARG PYTHON_VERSION=3.13.0
ARG NODE_VERSION=22.10.0
EOF

    # Create lib/features directory
    mkdir -p "$test_dir/lib/features"

    # Create mock JSON with updates
    command cat >"$test_dir/test.json" <<'EOF'
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
    echo '#!/bin/bash' >bin/release.sh
    echo 'echo "1.4.1" > VERSION' >>bin/release.sh
    chmod +x bin/release.sh
    echo "1.4.0" >VERSION

    # Run update with --no-commit to avoid git operations
    PROJECT_ROOT_OVERRIDE="$test_dir" "$PROJECT_ROOT/bin/update-versions.sh" --no-commit --no-bump --input test.json >/dev/null 2>&1

    # Check that file was modified
    if command grep -q "ARG PYTHON_VERSION=3.13.6" Dockerfile; then
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
    command cat >"$test_dir/test.json" <<'EOF'
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

    if echo "$output" | command grep -q "All versions are up to date"; then
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

    if echo "$output" | command grep -q "Error: Input file not found"; then
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
    command cat >"$test_dir/lib/features/dev-tools.sh" <<'EOF'
#!/bin/bash
LAZYGIT_VERSION="0.54.1"
DIRENV_VERSION="2.37.1"
EOF

    # Create mock JSON with shell script update
    command cat >"$test_dir/test.json" <<'EOF'
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
    echo '#!/bin/bash' >bin/release.sh
    echo 'echo "1.4.1" > VERSION' >>bin/release.sh
    chmod +x bin/release.sh
    echo "1.4.0" >VERSION

    # Run update
    PROJECT_ROOT_OVERRIDE="$test_dir" "$PROJECT_ROOT/bin/update-versions.sh" --no-commit --no-bump --input test.json >/dev/null 2>&1

    # Check that file was modified
    if command grep -q 'LAZYGIT_VERSION="0.54.2"' lib/features/dev-tools.sh; then
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
    command cat >"$test_dir/lib/features/java-dev.sh" <<'EOF'
#!/bin/bash
SPRING_VERSION="3.4.2"
JBANG_VERSION="0.121.0"
    MVND_VERSION="1.0.2"
GJF_VERSION="1.25.2"
EOF

    # Create mock JSON with Java tool updates
    command cat >"$test_dir/test.json" <<'EOF'
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
    echo '#!/bin/bash' >bin/release.sh
    echo 'echo "1.4.1" > VERSION' >>bin/release.sh
    chmod +x bin/release.sh
    echo "1.4.0" >VERSION

    # Run update
    PROJECT_ROOT_OVERRIDE="$test_dir" "$PROJECT_ROOT/bin/update-versions.sh" --no-commit --no-bump --input test.json >/dev/null 2>&1

    # Check that all Java tools were updated
    local all_updated=true
    if ! command grep -q 'SPRING_VERSION="3.5.4"' lib/features/java-dev.sh; then
        all_updated=false
    fi
    if ! command grep -q 'JBANG_VERSION="0.129.0"' lib/features/java-dev.sh; then
        all_updated=false
    fi
    if ! command grep -q 'MVND_VERSION="1.0.3"' lib/features/java-dev.sh; then
        all_updated=false
    fi
    if ! command grep -q 'GJF_VERSION="1.28.0"' lib/features/java-dev.sh; then
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
    command cat >"$test_dir/lib/features/dev-tools.sh" <<'EOF'
#!/bin/bash
DUF_VERSION="0.8.0"
DUA_VERSION="${DUA_VERSION:-2.34.0}"
ENTR_VERSION="5.5"
EOF

    # Create mock JSON with tool updates. dua sits next to duf and shares the
    # same VERSION pattern — easy to confuse, so cover both to guard the
    # "Unknown shell script tool" regression.
    command cat >"$test_dir/test.json" <<'EOF'
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
      "tool": "dua",
      "current": "2.34.0",
      "latest": "2.37.0",
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
    echo '#!/bin/bash' >bin/release.sh
    echo 'echo "1.4.1" > VERSION' >>bin/release.sh
    chmod +x bin/release.sh
    echo "1.4.0" >VERSION

    # Run update
    PROJECT_ROOT_OVERRIDE="$test_dir" "$PROJECT_ROOT/bin/update-versions.sh" --no-commit --no-bump --input test.json >/dev/null 2>&1

    # Check that both tools were updated
    local all_updated=true
    if ! command grep -q 'DUF_VERSION="0.8.1"' lib/features/dev-tools.sh; then
        all_updated=false
    fi
    if ! command grep -q 'DUA_VERSION="${DUA_VERSION:-2.37.0}"' lib/features/dev-tools.sh; then
        all_updated=false
    fi
    if ! command grep -q 'ENTR_VERSION="5.7"' lib/features/dev-tools.sh; then
        all_updated=false
    fi

    command rm -rf "$test_dir"

    if [ "$all_updated" = true ]; then
        return 0
    else
        return 1
    fi
}

# Test: just, rumdl, conform updates (regression for "Unknown shell script tool" warnings).
# conform also exercises the prerelease version format (e.g. 0.1.0-alpha.31).
test_just_rumdl_conform_update() {
    local test_dir
    test_dir=$(mktemp -d)

    mkdir -p "$test_dir/lib/features"
    command cat >"$test_dir/lib/features/dev-tools.sh" <<'EOF'
#!/bin/bash
JUST_VERSION="${JUST_VERSION:-1.48.0}"
RUMDL_VERSION="${RUMDL_VERSION:-0.1.76}"
CONFORM_VERSION="${CONFORM_VERSION:-0.1.0-alpha.30}"
EOF

    command cat >"$test_dir/test.json" <<'EOF'
{
  "tools": [
    {"tool": "just",     "current": "1.48.0",         "latest": "1.50.0",         "file": "dev-tools.sh", "status": "outdated"},
    {"tool": "rumdl",    "current": "0.1.76",         "latest": "0.1.81",         "file": "dev-tools.sh", "status": "outdated"},
    {"tool": "conform",  "current": "0.1.0-alpha.30", "latest": "0.1.0-alpha.31", "file": "dev-tools.sh", "status": "outdated"}
  ]
}
EOF

    cd "$test_dir"
    git init --quiet
    git config user.email "test@example.com"
    git config user.name "Test User"
    git add -A
    git commit -m "Initial" --quiet

    mkdir -p bin
    echo '#!/bin/bash' >bin/release.sh
    echo 'echo "1.4.1" > VERSION' >>bin/release.sh
    chmod +x bin/release.sh
    echo "1.4.0" >VERSION

    local output
    output=$(PROJECT_ROOT_OVERRIDE="$test_dir" "$PROJECT_ROOT/bin/update-versions.sh" --no-commit --no-bump --input test.json 2>&1)

    local all_updated=true
    if ! command grep -q 'JUST_VERSION="${JUST_VERSION:-1.50.0}"' lib/features/dev-tools.sh; then
        all_updated=false
    fi
    if ! command grep -q 'RUMDL_VERSION="${RUMDL_VERSION:-0.1.81}"' lib/features/dev-tools.sh; then
        all_updated=false
    fi
    if ! command grep -q 'CONFORM_VERSION="${CONFORM_VERSION:-0.1.0-alpha.31}"' lib/features/dev-tools.sh; then
        all_updated=false
    fi
    # Regression: must not warn about these tools being unknown.
    if echo "$output" | command grep -qE "Unknown shell script tool: (just|rumdl|conform)"; then
        all_updated=false
    fi

    command rm -rf "$test_dir"

    if [ "$all_updated" = true ]; then
        return 0
    else
        return 1
    fi
}
test_invalid_version_validation() {
    # Create temporary test directory
    local test_dir
    test_dir=$(mktemp -d)

    # Create mock Dockerfile
    command cat >"$test_dir/Dockerfile" <<'EOF'
ARG PYTHON_VERSION=3.13.0
ARG NODE_VERSION=22.10.0
ARG GO_VERSION=1.22.3
ARG RUST_VERSION=1.80.0
EOF

    # Create mock JSON with invalid versions
    command cat >"$test_dir/test.json" <<'EOF'
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
    echo '#!/bin/bash' >bin/release.sh
    echo 'echo "1.4.1" > VERSION' >>bin/release.sh
    chmod +x bin/release.sh
    echo "1.4.0" >VERSION

    # Run update with --no-commit to avoid git operations
    output=$(PROJECT_ROOT_OVERRIDE="$test_dir" "$PROJECT_ROOT/bin/update-versions.sh" --no-commit --no-bump --input test.json 2>&1)

    # Check that invalid versions were rejected and files were not modified
    local success=true

    # Check output contains error messages
    if ! echo "$output" | command grep -q "Invalid version format"; then
        success=false
    fi

    # Check that no invalid versions were written to Dockerfile
    if command grep -q "null\|undefined\|error" Dockerfile; then
        success=false
    fi

    # Check original versions are still there
    if ! command grep -q "ARG PYTHON_VERSION=3.13.0" Dockerfile; then
        success=false
    fi
    if ! command grep -q "ARG NODE_VERSION=22.10.0" Dockerfile; then
        success=false
    fi
    if ! command grep -q "ARG GO_VERSION=1.22.3" Dockerfile; then
        success=false
    fi
    if ! command grep -q "ARG RUST_VERSION=1.80.0" Dockerfile; then
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
    command cat >"$test_dir/Dockerfile" <<'EOF'
ARG PYTHON_VERSION=3.13.0
ARG NODE_VERSION=22.10.0
ARG GO_VERSION=1.22.3
EOF

    # Create mock JSON with mixed valid and invalid versions
    command cat >"$test_dir/test.json" <<'EOF'
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
    echo '#!/bin/bash' >bin/release.sh
    echo 'echo "1.4.1" > VERSION' >>bin/release.sh
    chmod +x bin/release.sh
    echo "1.4.0" >VERSION

    # Run update
    output=$(PROJECT_ROOT_OVERRIDE="$test_dir" "$PROJECT_ROOT/bin/update-versions.sh" --no-commit --no-bump --input test.json 2>&1)

    # Check that valid versions were updated and invalid ones were rejected
    local success=true

    # Python should be updated (valid)
    if ! command grep -q "ARG PYTHON_VERSION=3.13.6" Dockerfile; then
        success=false
    fi

    # Node.js should NOT be updated (invalid)
    if ! command grep -q "ARG NODE_VERSION=22.10.0" Dockerfile; then
        success=false
    fi

    # Go should be updated (valid)
    if ! command grep -q "ARG GO_VERSION=1.25.0" Dockerfile; then
        success=false
    fi

    # Check that "null" was not written
    if command grep -q "null" Dockerfile; then
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
    command cat >"$test_dir/lib/base/setup.sh" <<'EOF'
#!/bin/bash
# Base system setup

echo "=== Installing zoxide ==="
ARCH=$(dpkg --print-architecture)
ZOXIDE_VERSION="0.9.0"
cd /tmp
EOF

    # Create mock version check output
    command cat >"$test_dir/test.json" <<'EOF'
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
    echo '#!/bin/bash' >bin/release.sh
    echo 'echo "1.0.1" > VERSION' >>bin/release.sh
    chmod +x bin/release.sh
    echo "1.0.0" >VERSION

    # Run update
    PROJECT_ROOT_OVERRIDE="$test_dir" "$PROJECT_ROOT/bin/update-versions.sh" --no-commit --no-bump --input test.json >/dev/null 2>&1

    # Check that zoxide was updated
    local updated=false
    if command grep -q 'ZOXIDE_VERSION="0.9.8"' lib/base/setup.sh; then
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
run_test test_just_rumdl_conform_update "Updates just, rumdl, and conform (incl. prerelease format)"
run_test test_update_zoxide_version "Updates zoxide version in base setup"
run_test test_invalid_version_validation "Rejects invalid version formats (null, undefined, error)"
run_test test_mixed_valid_invalid_versions "Updates valid versions while rejecting invalid ones"

# Test removed: kubernetes-checksums.sh no longer exists
# Kubernetes, dev-tools, and golang now use dynamic checksum fetching
# Checksums are fetched at build time from upstream sources

# Test: krew update handler exists
test_krew_update_handler() {
    # Check that update-versions.sh has krew update handling
    if command grep -q "krew)" "$PROJECT_ROOT/bin/lib/update-versions/updaters.sh"; then
        assert_true true "update-versions.sh has krew update handler"
    else
        assert_true false "update-versions.sh missing krew update handler"
    fi

    # Check that it updates KREW_VERSION in Dockerfile
    if command grep -q "ARG KREW_VERSION=" "$PROJECT_ROOT/bin/lib/update-versions/updaters.sh"; then
        assert_true true "update-versions.sh updates KREW_VERSION"
    else
        assert_true false "update-versions.sh missing KREW_VERSION update"
    fi
}

# Test: Helm update handler exists
test_helm_update_handler() {
    # Check that update-versions.sh has Helm update handling
    if command grep -q "Helm)" "$PROJECT_ROOT/bin/lib/update-versions/updaters.sh"; then
        assert_true true "update-versions.sh has Helm update handler"
    else
        assert_true false "update-versions.sh missing Helm update handler"
    fi

    # Check that it updates HELM_VERSION in Dockerfile
    if command grep -q "ARG HELM_VERSION=" "$PROJECT_ROOT/bin/lib/update-versions/updaters.sh"; then
        assert_true true "update-versions.sh updates HELM_VERSION"
    else
        assert_true false "update-versions.sh missing HELM_VERSION update"
    fi
}

# Test: mise, vale, typos updates (regression — these were silently skipped with
# "Unknown tool" warnings while still counted as applied, which stalled v4.19.6).
test_mise_vale_typos_update() {
    local test_dir
    test_dir=$(mktemp -d)

    command cat >"$test_dir/Dockerfile" <<'EOF'
ARG MISE_VERSION=2026.5.6
EOF

    mkdir -p "$test_dir/lib/features"
    command cat >"$test_dir/lib/features/mise.sh" <<'EOF'
#!/bin/bash
MISE_VERSION="${MISE_VERSION:-2026.5.6}"
EOF
    command cat >"$test_dir/lib/features/dev-tools.sh" <<'EOF'
#!/bin/bash
VALE_VERSION="${VALE_VERSION:-3.14.1}"
TYPOS_VERSION="${TYPOS_VERSION:-1.46.1}"
EOF

    command cat >"$test_dir/test.json" <<'EOF'
{
  "tools": [
    {"tool": "Mise",  "current": "2026.5.6", "latest": "2026.6.10", "file": "Dockerfile",   "status": "outdated"},
    {"tool": "vale",  "current": "3.14.1",   "latest": "3.15.1",    "file": "dev-tools.sh", "status": "outdated"},
    {"tool": "typos", "current": "1.46.1",   "latest": "1.47.2",    "file": "dev-tools.sh", "status": "outdated"}
  ]
}
EOF

    cd "$test_dir"
    git init --quiet
    git config user.email "test@example.com"
    git config user.name "Test User"
    git add -A
    git commit -m "Initial" --quiet

    mkdir -p bin
    echo '#!/bin/bash' >bin/release.sh
    echo 'echo "1.4.1" > VERSION' >>bin/release.sh
    chmod +x bin/release.sh
    echo "1.4.0" >VERSION

    local output
    output=$(PROJECT_ROOT_OVERRIDE="$test_dir" "$PROJECT_ROOT/bin/update-versions.sh" --no-commit --no-bump --input test.json 2>&1)

    local all_updated=true
    command grep -q "ARG MISE_VERSION=2026.6.10" Dockerfile || all_updated=false
    command grep -q 'MISE_VERSION="${MISE_VERSION:-2026.6.10}"' lib/features/mise.sh || all_updated=false
    command grep -q 'VALE_VERSION="${VALE_VERSION:-3.15.1}"' lib/features/dev-tools.sh || all_updated=false
    command grep -q 'TYPOS_VERSION="${TYPOS_VERSION:-1.47.2}"' lib/features/dev-tools.sh || all_updated=false
    # Regression: must not warn about these being unknown.
    if echo "$output" | command grep -qiE "Unknown (Dockerfile|shell script) tool: (Mise|vale|typos)"; then
        all_updated=false
    fi

    cd "$PROJECT_ROOT"
    command rm -rf "$test_dir"
    assert_true "$all_updated" "Mise, vale, typos all updated without Unknown-tool warnings"
}

# Test: an unmapped tool must FAIL loudly, not silently count as applied.
# (Prevents the v4.19.6-class silent skip.)
test_unknown_tool_fails_loudly() {
    local test_dir
    test_dir=$(mktemp -d)

    mkdir -p "$test_dir/lib/features"
    command cat >"$test_dir/lib/features/dev-tools.sh" <<'EOF'
#!/bin/bash
NOPE_VERSION="${NOPE_VERSION:-1.0.0}"
EOF

    command cat >"$test_dir/test.json" <<'EOF'
{
  "tools": [
    {"tool": "totally-unmapped-tool", "current": "1.0.0", "latest": "1.0.1", "file": "dev-tools.sh", "status": "outdated"}
  ]
}
EOF

    cd "$test_dir"
    git init --quiet
    git config user.email "test@example.com"
    git config user.name "Test User"
    git add -A
    git commit -m "Initial" --quiet

    mkdir -p bin
    echo '#!/bin/bash' >bin/release.sh
    echo 'echo "1.4.1" > VERSION' >>bin/release.sh
    chmod +x bin/release.sh
    echo "1.4.0" >VERSION

    local output
    output=$(PROJECT_ROOT_OVERRIDE="$test_dir" "$PROJECT_ROOT/bin/update-versions.sh" --no-commit --no-bump --input test.json 2>&1)

    cd "$PROJECT_ROOT"
    command rm -rf "$test_dir"

    # Must surface an ERROR and NOT report the bogus tool as an applied update.
    local ok=true
    echo "$output" | command grep -qiE "ERROR: Unknown shell script tool" || ok=false
    echo "$output" | command grep -qiE "No updates applied|Updates applied: 0" || ok=false
    if echo "$output" | command grep -qiE "Updates applied: [1-9]"; then
        ok=false
    fi
    assert_true "$ok" "Unmapped tool produces an error and applies nothing"
}

# ============================================================================
# Test: pin_action rewrites a SHA-pinned action to a fresh SHA pin + comment
# ============================================================================
# Hermetic: mock resolve_action_sha so the test never hits the network. The
# regression this guards is the corrupting rewrite — against an already
# SHA-pinned ref, the old tag-only sed produced `@v0.37.0<oldsha>`.
test_pin_action_rewrites_sha_pin() {
    source "$PROJECT_ROOT/bin/lib/common.sh"
    source "$PROJECT_ROOT/bin/lib/version-utils.sh"
    source "$PROJECT_ROOT/bin/lib/update-versions/updaters.sh"

    # Mock the network resolution to a deterministic SHA.
    local new_sha="abcabcabcabcabcabcabcabcabcabcabcabcabca"
    resolve_action_sha() { printf '%s\n' "abcabcabcabcabcabcabcabcabcabcabcabcabca"; }

    local wf="$RESULTS_DIR/pin_action_ci.yml"
    command cat >"$wf" <<'EOF'
      - uses: aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25 # v0.36.0
      - uses: aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25 # v0.36.0
EOF

    pin_action "$wf" "aquasecurity/trivy-action" "0.37.0" >/dev/null 2>&1

    local ok=true
    # Both lines carry the new SHA + `# v0.37.0`.
    [ "$(command grep -cE "trivy-action@${new_sha} # v0.37.0" "$wf")" = "2" ] || ok=false
    # No corrupted `@v<ver><sha>` ref, and old SHA is gone.
    if command grep -qE '@v[0-9.]+[0-9a-f]{40}' "$wf"; then ok=false; fi
    if command grep -q 'ed142fd0673e97e23eac54620cfb913e5ce36c25' "$wf"; then ok=false; fi

    command rm -f "$wf"
    assert_true "$ok" "pin_action rewrites both refs to a clean SHA pin with version comment"
}

# ============================================================================
# Test: pin_action leaves the pin untouched when the SHA can't be resolved.
# ============================================================================
# A stale-but-valid SHA pin is far safer than a mutable tag or a corrupt ref,
# so an unresolvable version must be a no-op failure, not a partial rewrite.
test_pin_action_preserves_pin_on_resolution_failure() {
    source "$PROJECT_ROOT/bin/lib/common.sh"
    source "$PROJECT_ROOT/bin/lib/version-utils.sh"
    source "$PROJECT_ROOT/bin/lib/update-versions/updaters.sh"

    # Mock resolution failure.
    resolve_action_sha() { return 1; }

    local wf="$RESULTS_DIR/pin_action_fail_ci.yml"
    command cat >"$wf" <<'EOF'
      - uses: aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25 # v0.36.0
EOF
    local before
    before=$(command cat "$wf")

    local rc=0
    pin_action "$wf" "aquasecurity/trivy-action" "99.99.99" >/dev/null 2>&1 || rc=$?

    local ok=true
    [ "$rc" -eq 1 ] || ok=false
    [ "$(command cat "$wf")" = "$before" ] || ok=false

    command rm -f "$wf"
    assert_true "$ok" "pin_action fails (rc=1) and leaves the file byte-identical on resolution failure"
}

# ============================================================================
# Test: every unknown-tool fallback returns RC_NO_UPDATER_CASE
# ============================================================================
# update_version() dispatches on file type, and EACH branch has its own `*)`
# fallback. They must all report a missing case the same way — one branch
# returning 0 makes update-versions.sh count an unrewritten tool as a
# successful update, which is the silent stall issue #781 exists to close.
# (The setup.sh branch did exactly that: it warned and fell through, so the
# arm returned echo's status.) A static case-label scan cannot catch this, so
# assert the actual return code for all four file types.
test_unknown_tool_returns_no_updater_case_for_every_file_type() {
    source "$PROJECT_ROOT/bin/lib/common.sh"
    source "$PROJECT_ROOT/bin/lib/version-utils.sh"
    source "$PROJECT_ROOT/bin/lib/update-versions/updaters.sh"

    # shellcheck disable=SC2034 # consumed by update_version() from the sourced updaters.sh
    local DRY_RUN=false
    local ok=true
    local file rc

    # One representative file name per branch of the outer `case "$file"`.
    for file in Dockerfile setup.sh dev-tools.sh ci.yml some-unknown-file.txt; do
        rc=0
        update_version "totally-unmapped-tool" "1.0.0" "1.0.1" "$file" >/dev/null 2>&1 || rc=$?
        if [ "$rc" -ne "$RC_NO_UPDATER_CASE" ]; then
            echo "    $file: expected RC_NO_UPDATER_CASE ($RC_NO_UPDATER_CASE), got $rc"
            ok=false
        fi
    done

    assert_true "$ok" "Every file-type branch returns RC_NO_UPDATER_CASE for an unmapped tool"
}

# ============================================================================
# Test: a malformed version is reported separately from a missing case
# ============================================================================
# The two used to share exit 1, which is why the summary mislabeled missing
# cases as "invalid versions".
test_invalid_version_returns_distinct_code() {
    source "$PROJECT_ROOT/bin/lib/common.sh"
    source "$PROJECT_ROOT/bin/lib/version-utils.sh"
    source "$PROJECT_ROOT/bin/lib/update-versions/updaters.sh"

    # shellcheck disable=SC2034 # consumed by update_version() from the sourced updaters.sh
    local DRY_RUN=false
    local rc=0
    update_version "sd" "1.1.0" "not-a-version" "dev-tools.sh" >/dev/null 2>&1 || rc=$?

    local ok=true
    [ "$rc" -eq "$RC_INVALID_VERSION" ] || ok=false
    [ "$RC_INVALID_VERSION" -ne "$RC_NO_UPDATER_CASE" ] || ok=false

    assert_true "$ok" "A malformed version returns RC_INVALID_VERSION, distinct from RC_NO_UPDATER_CASE"
}

# ============================================================================
# Test: the exit-code contract auto-patch.yml depends on
# ============================================================================
# .github/workflows/auto-patch.yml treats exit 2 as "some tools were skipped,
# keep the updates that applied" and any other non-zero as a hard failure. If
# this contract changes, that workflow silently mis-handles the run.
_run_update_versions_fixture() {
    local payload="$1"
    shift
    local test_dir
    test_dir=$(mktemp -d)

    mkdir -p "$test_dir/lib/features"
    command cat >"$test_dir/lib/features/dev-tools.sh" <<'EOF'
#!/bin/bash
SD_VERSION="${SD_VERSION:-1.1.0}"
EOF
    printf '%s' "$payload" >"$test_dir/test.json"

    local rc=0
    (
        cd "$test_dir" || exit 1
        PROJECT_ROOT_OVERRIDE="$test_dir" "$PROJECT_ROOT/bin/update-versions.sh" \
            --no-commit --no-bump --input test.json "$@" >/dev/null 2>&1
    ) || rc=$?

    command rm -rf "$test_dir"
    printf '%s' "$rc"
}

test_exit_code_contract() {
    local missing_case='{"tools":[{"tool":"totally-unmapped-tool","current":"1.0.0","latest":"1.0.1","file":"dev-tools.sh","status":"outdated"}]}'
    local invalid='{"tools":[{"tool":"sd","current":"1.1.0","latest":"not-a-version","file":"dev-tools.sh","status":"outdated"}]}'
    local clean='{"tools":[{"tool":"sd","current":"1.1.0","latest":"1.2.0","file":"dev-tools.sh","status":"outdated"}]}'

    local ok=true
    local rc

    rc=$(_run_update_versions_fixture "$missing_case")
    [ "$rc" -eq 2 ] || {
        echo "    missing case: expected exit 2, got $rc"
        ok=false
    }

    rc=$(_run_update_versions_fixture "$invalid")
    [ "$rc" -eq 2 ] || {
        echo "    invalid version: expected exit 2, got $rc"
        ok=false
    }

    # A dry run changes nothing, so nothing is stalling — stays exit 0.
    rc=$(_run_update_versions_fixture "$missing_case" --dry-run)
    [ "$rc" -eq 0 ] || {
        echo "    dry run: expected exit 0, got $rc"
        ok=false
    }

    # A run where everything applied must still succeed.
    rc=$(_run_update_versions_fixture "$clean")
    [ "$rc" -eq 0 ] || {
        echo "    clean run: expected exit 0, got $rc"
        ok=false
    }

    assert_true "$ok" "exit 2 on skipped updates; 0 on a clean run and on --dry-run"
}

# ============================================================================
# Test: the three new cases actually rewrite their pins
# ============================================================================
# Exit status alone cannot prove a rewrite happened: sed_inplace runs `sed -i`,
# which exits 0 even when its pattern matches nothing. So a typo in one of
# these patterns would leave the pin untouched and still "succeed" — the exact
# silent stall issue #781 is about. Assert file content, not exit codes.
#
# hyperfine is the one that most needs this: HYPERFINE_VERSION (dev-tools.sh)
# and HYPERFINE_CARGO_VERSION (rust-dev.sh) share a prefix, so the check also
# confirms bumping one leaves the other alone.
test_new_cases_rewrite_their_pins() {
    local test_dir
    test_dir=$(mktemp -d)

    mkdir -p "$test_dir/lib/features"
    command cat >"$test_dir/lib/features/dev-tools.sh" <<'EOF'
#!/bin/bash
SD_VERSION="${SD_VERSION:-1.1.0}"
HYPERFINE_VERSION="${HYPERFINE_VERSION:-1.20.0}"
JSONC_PARSER_VERSION="${JSONC_PARSER_VERSION:-3.3.1}"
EOF
    command cat >"$test_dir/lib/features/rust-dev.sh" <<'EOF'
#!/bin/bash
HYPERFINE_CARGO_VERSION="${HYPERFINE_CARGO_VERSION:-1.20.0}"
EOF

    command cat >"$test_dir/test.json" <<'EOF'
{
  "tools": [
    {"tool": "sd", "current": "1.1.0", "latest": "1.2.0", "file": "dev-tools.sh", "status": "outdated"},
    {"tool": "hyperfine", "current": "1.20.0", "latest": "1.21.0", "file": "dev-tools.sh", "status": "outdated"},
    {"tool": "jsonc-parser", "current": "3.3.1", "latest": "3.4.0", "file": "dev-tools.sh", "status": "outdated"}
  ]
}
EOF

    (
        cd "$test_dir" || exit 1
        PROJECT_ROOT_OVERRIDE="$test_dir" "$PROJECT_ROOT/bin/update-versions.sh" \
            --no-commit --no-bump --input test.json >/dev/null 2>&1
    ) || true

    local ok=true
    local dev_tools="$test_dir/lib/features/dev-tools.sh"

    command grep -q 'SD_VERSION="${SD_VERSION:-1.2.0}"' "$dev_tools" || {
        echo "    sd: SD_VERSION was not rewritten to 1.2.0"
        ok=false
    }
    command grep -q 'HYPERFINE_VERSION="${HYPERFINE_VERSION:-1.21.0}"' "$dev_tools" || {
        echo "    hyperfine: HYPERFINE_VERSION was not rewritten to 1.21.0"
        ok=false
    }
    command grep -q 'JSONC_PARSER_VERSION="${JSONC_PARSER_VERSION:-3.4.0}"' "$dev_tools" || {
        echo "    jsonc-parser: JSONC_PARSER_VERSION was not rewritten to 3.4.0"
        ok=false
    }
    # The sibling cargo pin must be untouched by the hyperfine bump.
    command grep -q 'HYPERFINE_CARGO_VERSION="${HYPERFINE_CARGO_VERSION:-1.20.0}"' \
        "$test_dir/lib/features/rust-dev.sh" || {
        echo "    hyperfine: HYPERFINE_CARGO_VERSION was disturbed (should stay 1.20.0)"
        ok=false
    }

    command rm -rf "$test_dir"
    assert_true "$ok" "hyperfine, jsonc-parser, and sd rewrite their own pins and nothing else"
}

# ============================================================================
# Test: a failed rewrite exits 3, not 2
# ============================================================================
# auto-patch.yml tolerates exit 2 (nothing was written, tools just stalled) but
# must FAIL on a rewrite that broke after its case matched — that can leave the
# tree half-updated (a Dockerfile ARG bumped without its vendored catalog
# entry, issue #506), which must never reach auto-merge.
test_failed_rewrite_exits_three() {
    local test_dir
    test_dir=$(mktemp -d)

    # Trivy-action lives in the ci.yml branch and routes through pin_action,
    # which fails when it cannot resolve a SHA. Point it at a workflow file
    # that exists but an unresolvable version, with no network access needed:
    # resolve_action_sha returns non-zero on any failure, including no network.
    mkdir -p "$test_dir/.github/workflows"
    command cat >"$test_dir/.github/workflows/ci.yml" <<'EOF'
jobs:
  build:
    steps:
      - uses: aquasecurity/trivy-action@0000000000000000000000000000000000000000 # v0.1.0
EOF

    command cat >"$test_dir/test.json" <<'EOF'
{
  "tools": [
    {"tool": "trivy-action", "current": "0.1.0", "latest": "0.0.0-nonexistent-tag", "file": "ci.yml", "status": "outdated"}
  ]
}
EOF

    local rc=0
    (
        cd "$test_dir" || exit 1
        PROJECT_ROOT_OVERRIDE="$test_dir" GITHUB_TOKEN="" \
            "$PROJECT_ROOT/bin/update-versions.sh" \
            --no-commit --no-bump --input test.json >/dev/null 2>&1
    ) || rc=$?

    command rm -rf "$test_dir"

    assert_equals 3 "$rc" "A failed rewrite exits 3 (fatal to CI), not 2 (tolerated skip)"
}

# ============================================================================
# Test: each failure cause is reported under its own label, naming the tool
# ============================================================================
# The old summary lumped everything under "invalid versions" and, worse, only
# printed inside the `UPDATES_APPLIED` branch — so a run where EVERY update
# failed printed no failure count at all.
test_failure_summary_separates_causes() {
    local test_dir
    test_dir=$(mktemp -d)

    mkdir -p "$test_dir/lib/features"
    command cat >"$test_dir/lib/features/dev-tools.sh" <<'EOF'
#!/bin/bash
SD_VERSION="${SD_VERSION:-1.1.0}"
EOF

    command cat >"$test_dir/test.json" <<'EOF'
{
  "tools": [
    {"tool": "totally-unmapped-tool", "current": "1.0.0", "latest": "1.0.1", "file": "dev-tools.sh", "status": "outdated"},
    {"tool": "sd", "current": "1.1.0", "latest": "not-a-version", "file": "dev-tools.sh", "status": "outdated"}
  ]
}
EOF

    local output
    output=$(
        cd "$test_dir" || exit 1
        PROJECT_ROOT_OVERRIDE="$test_dir" "$PROJECT_ROOT/bin/update-versions.sh" \
            --no-commit --no-bump --input test.json 2>&1
    ) || true

    command rm -rf "$test_dir"

    local ok=true
    # Both causes reported, each naming its tool — and NOT collapsed into one.
    echo "$output" | command grep -q "no updater case" || ok=false
    echo "$output" | command grep -q "totally-unmapped-tool" || ok=false
    echo "$output" | command grep -q "invalid version strings" || ok=false

    assert_true "$ok" "Missing-case and invalid-version failures are reported separately, naming the tools"
}

# Test removed - kubernetes-checksums.sh no longer needed (uses dynamic fetching)
run_test test_krew_update_handler "krew update handler exists"
run_test test_helm_update_handler "Helm update handler exists"
run_test test_mise_vale_typos_update "Updates Mise, vale, typos (regression for silent skip)"
run_test test_unknown_tool_fails_loudly "Unknown tool fails loudly instead of silent success"
run_test test_pin_action_rewrites_sha_pin "pin_action rewrites SHA-pinned action without corruption"
run_test test_pin_action_preserves_pin_on_resolution_failure "pin_action preserves pin when SHA resolution fails"
run_test test_unknown_tool_returns_no_updater_case_for_every_file_type "Every file-type branch returns RC_NO_UPDATER_CASE for an unmapped tool"
run_test test_invalid_version_returns_distinct_code "Invalid version returns a code distinct from a missing case"
run_test test_exit_code_contract "Exit-code contract: 2 on skipped updates, 0 on clean and dry runs"
run_test test_new_cases_rewrite_their_pins "hyperfine, jsonc-parser, and sd rewrite their own pins"
run_test test_failed_rewrite_exits_three "Failed rewrite exits 3 (fatal), not 2 (tolerated)"
run_test test_failure_summary_separates_causes "Failure summary separates causes and names the tools"

# Generate report
generate_report
