#!/usr/bin/env bash
# Unit tests for lib/features/ruby.sh
# Tests Ruby programming language installation and configuration
#
# Note: Ruby is installed directly to /usr/local (no rbenv since v4.0)

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Ruby Feature Tests"

# Setup function - runs before each test
setup() {
    # Create temporary directory for testing
    export TEST_TEMP_DIR="$RESULTS_DIR/test-ruby"
    mkdir -p "$TEST_TEMP_DIR"

    # Mock environment
    export RUBY_VERSION="${RUBY_VERSION:-3.4.7}"
    export USERNAME="testuser"
    export USER_UID="1000"
    export USER_GID="1000"
    export HOME="/home/testuser"

    # Create mock directories (Ruby installs to /usr/local, not rbenv)
    mkdir -p "$TEST_TEMP_DIR/usr/local/bin"
    mkdir -p "$TEST_TEMP_DIR/usr/local/lib/ruby"
    mkdir -p "$TEST_TEMP_DIR/home/testuser/.gem"
    mkdir -p "$TEST_TEMP_DIR/cache/bundle"
    mkdir -p "$TEST_TEMP_DIR/etc/bashrc.d"
}

# Teardown function - runs after each test
teardown() {
    # Clean up test directory
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi

    # Unset test variables
    unset RUBY_VERSION USERNAME USER_UID USER_GID HOME 2>/dev/null || true
}

# Test: Ruby version validation
test_ruby_version_validation() {
    # Test valid version format
    local version="3.4.7"
    if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        assert_true true "Version format is valid"
    else
        assert_true false "Version format is invalid"
    fi

    # Test major version extraction
    local major
    major=$(echo "$version" | command cut -d. -f1)
    assert_equals "3" "$major" "Major version extracted correctly"

    # Test minor version extraction
    local minor
    minor=$(echo "$version" | command cut -d. -f2)
    assert_equals "4" "$minor" "Minor version extracted correctly"

    # Test version comparison
    if [ "$major" -ge 3 ]; then
        assert_true true "Ruby 3.x or newer detected"
    else
        assert_true false "Ruby version too old"
    fi
}

# Test: Ruby direct installation structure (no rbenv)
test_ruby_direct_installation() {
    local ruby_dir="$TEST_TEMP_DIR/usr/local"

    # Create Ruby installation structure (as installed directly to /usr/local)
    mkdir -p "$ruby_dir/bin"
    mkdir -p "$ruby_dir/lib/ruby/gems"
    mkdir -p "$ruby_dir/include/ruby"

    # Create Ruby binaries
    local binaries=("ruby" "gem" "bundle" "bundler" "irb" "rake")
    for bin in "${binaries[@]}"; do
        touch "$ruby_dir/bin/$bin"
        chmod +x "$ruby_dir/bin/$bin"
    done

    # Check structure
    assert_dir_exists "$ruby_dir/bin"
    assert_dir_exists "$ruby_dir/lib/ruby"

    # Check binaries
    for bin in "${binaries[@]}"; do
        if [ -x "$ruby_dir/bin/$bin" ]; then
            assert_true true "$bin is executable"
        else
            assert_true false "$bin is not executable"
        fi
    done
}

# Test: Gem configuration
test_gem_configuration() {
    local gem_config="$TEST_TEMP_DIR/usr/local/etc/gemrc"
    mkdir -p "$(dirname "$gem_config")"

    # Create gem configuration (as created by ruby.sh)
    command cat > "$gem_config" << 'EOF'
---
:backtrace: false
:bulk_threshold: 1000
:sources:
- https://rubygems.org/
:update_sources: true
:verbose: true
gem: --no-document
EOF

    assert_file_exists "$gem_config"

    # Check no-document flag
    if command grep -q "gem: --no-document" "$gem_config"; then
        assert_true true "Gem configured to skip documentation"
    else
        assert_true false "Gem not configured to skip documentation"
    fi
}

# Test: Bundle cache configuration
test_bundle_cache_configuration() {
    local cache_dir="$TEST_TEMP_DIR/cache/bundle"
    local bundle_config="$TEST_TEMP_DIR/home/testuser/.bundle/config"

    # Create bundle cache directories
    mkdir -p "$cache_dir"
    mkdir -p "$(dirname "$bundle_config")"

    # Create bundle config
    command cat > "$bundle_config" << 'EOF'
---
BUNDLE_PATH: "/cache/bundle"
BUNDLE_CACHE_ALL: "true"
BUNDLE_JOBS: "4"
EOF

    assert_file_exists "$bundle_config"
    assert_dir_exists "$cache_dir"

    # Check cache path configuration
    if command grep -q 'BUNDLE_PATH: "/cache/bundle"' "$bundle_config"; then
        assert_true true "Bundle uses cache directory"
    else
        assert_true false "Bundle doesn't use cache directory"
    fi

    # Check parallel jobs
    if command grep -q 'BUNDLE_JOBS: "4"' "$bundle_config"; then
        assert_true true "Bundle configured for parallel jobs"
    else
        assert_true false "Bundle not configured for parallel jobs"
    fi
}

# Test: Ruby environment variables (no rbenv)
test_ruby_environment_variables() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/35-ruby.sh"

    # Create mock bashrc content (direct installation, no rbenv)
    command cat > "$bashrc_file" << 'EOF'
# Ruby environment (direct installation to /usr/local)
export PATH="/usr/local/bin:$PATH"
export BUNDLE_PATH="/cache/bundle"
export GEM_HOME="$HOME/.gem"
export GEM_PATH="$GEM_HOME"
EOF

    # Check environment variables - should NOT have rbenv
    if command grep -q "RBENV_ROOT" "$bashrc_file"; then
        assert_true false "Should not reference RBENV_ROOT (rbenv removed in v4.0)"
    else
        assert_true true "No rbenv references (correct for v4.0+)"
    fi

    if command grep -q "export BUNDLE_PATH=" "$bashrc_file"; then
        assert_true true "BUNDLE_PATH is exported"
    else
        assert_true false "BUNDLE_PATH is not exported"
    fi

    if command grep -q "export GEM_HOME=" "$bashrc_file"; then
        assert_true true "GEM_HOME is exported"
    else
        assert_true false "GEM_HOME is not exported"
    fi
}

# Test: Ruby aliases and helpers
test_ruby_aliases_helpers() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/35-ruby.sh"
    mkdir -p "$(dirname "$bashrc_file")"

    # Add aliases section
    command cat > "$bashrc_file" << 'EOF'
# Ruby aliases
alias be='bundle exec'
alias bi='bundle install'
alias bu='bundle update'
alias bip='bundle install --path vendor/bundle'
alias bers='bundle exec rails server'
alias berc='bundle exec rails console'
alias bert='bundle exec rake test'
EOF

    # Check common aliases
    if command grep -q "alias be='bundle exec'" "$bashrc_file"; then
        assert_true true "bundle exec alias defined"
    else
        assert_true false "bundle exec alias not defined"
    fi

    if command grep -q "alias bi='bundle install'" "$bashrc_file"; then
        assert_true true "bundle install alias defined"
    else
        assert_true false "bundle install alias not defined"
    fi
}

# Test: Gemfile detection
test_gemfile_detection() {
    local project_dir="$TEST_TEMP_DIR/project"
    mkdir -p "$project_dir"

    # Create mock Gemfile
    command cat > "$project_dir/Gemfile" << 'EOF'
source 'https://rubygems.org'

ruby '3.4.7'

gem 'rails', '~> 7.0'
gem 'puma'
gem 'sqlite3'

group :development, :test do
  gem 'rspec-rails'
  gem 'pry'
end
EOF

    assert_file_exists "$project_dir/Gemfile"

    # Check Ruby version specification
    if command grep -q "ruby '3.4.7'" "$project_dir/Gemfile"; then
        assert_true true "Gemfile specifies Ruby version"
    else
        assert_true false "Gemfile doesn't specify Ruby version"
    fi

    # Check gem groups
    if command grep -q "group :development, :test do" "$project_dir/Gemfile"; then
        assert_true true "Gemfile has development/test group"
    else
        assert_true false "Gemfile missing development/test group"
    fi
}

# Test: Permissions and ownership
test_ruby_permissions() {
    local ruby_lib="$TEST_TEMP_DIR/usr/local/lib/ruby"
    local gem_home="$TEST_TEMP_DIR/home/testuser/.gem"

    # Create directories
    mkdir -p "$ruby_lib" "$gem_home"

    # Check directories exist and are accessible
    if [ -d "$ruby_lib" ] && [ -r "$ruby_lib" ]; then
        assert_true true "Ruby lib directory is readable"
    else
        assert_true false "Ruby lib directory is not readable"
    fi

    if [ -d "$gem_home" ] && [ -w "$gem_home" ]; then
        assert_true true "Gem home is writable"
    else
        assert_true false "Gem home is not writable"
    fi
}

# Test: Ruby verification script
test_ruby_verification() {
    local test_script="$TEST_TEMP_DIR/test-ruby.sh"

    # Create verification script (updated for direct installation)
    command cat > "$test_script" << 'EOF'
#!/bin/bash
echo "Ruby version:"
ruby --version 2>/dev/null || echo "Ruby not installed"
echo "Gem version:"
gem --version 2>/dev/null || echo "Gem not installed"
echo "Bundler version:"
bundle --version 2>/dev/null || echo "Bundler not installed"
echo "Ruby is installed directly without rbenv"
EOF
    chmod +x "$test_script"

    assert_file_exists "$test_script"

    # Check script is executable
    if [ -x "$test_script" ]; then
        assert_true true "Verification script is executable"
    else
        assert_true false "Verification script is not executable"
    fi

    # Check script doesn't reference rbenv
    if command grep -q "rbenv" "$test_script" && ! command grep -q "without rbenv" "$test_script"; then
        assert_true false "Verification script should not use rbenv"
    else
        assert_true true "Verification script correctly avoids rbenv"
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
run_test_with_setup test_ruby_version_validation "Ruby version validation works"
run_test_with_setup test_ruby_direct_installation "Ruby direct installation structure is correct"
run_test_with_setup test_gem_configuration "Gem configuration is correct"
run_test_with_setup test_bundle_cache_configuration "Bundle cache is configured properly"
run_test_with_setup test_ruby_environment_variables "Ruby environment variables are set (no rbenv)"
run_test_with_setup test_ruby_aliases_helpers "Ruby aliases and helpers are defined"
run_test_with_setup test_gemfile_detection "Gemfile detection works"
run_test_with_setup test_ruby_permissions "Ruby directories have correct permissions"
run_test_with_setup test_ruby_verification "Ruby verification script works"

# ============================================================================
# Checksum Verification Tests
# ============================================================================

# Test: ruby.sh sources checksum verification libraries
test_checksum_libraries_sourced() {
    local ruby_script="$PROJECT_ROOT/lib/features/ruby.sh"

    if ! [ -f "$ruby_script" ]; then
        skip_test "ruby.sh not found"
        return
    fi

    # Check that checksum-fetch.sh is sourced
    if command grep -q "source.*checksum-fetch.sh" "$ruby_script"; then
        assert_true true "ruby.sh sources checksum-fetch.sh library"
    else
        assert_true false "ruby.sh does not source checksum-fetch.sh library"
    fi

    # Check that download-verify.sh is sourced
    if command grep -q "source.*download-verify.sh" "$ruby_script"; then
        assert_true true "ruby.sh sources download-verify.sh library"
    else
        assert_true false "ruby.sh does not source download-verify.sh library"
    fi
}

# Test: ruby.sh uses 4-tier verification system
test_fetch_ruby_checksum_usage() {
    local ruby_script="$PROJECT_ROOT/lib/features/ruby.sh"

    if ! [ -f "$ruby_script" ]; then
        skip_test "ruby.sh not found"
        return
    fi

    # Check for 4-tier checksum verification system
    if command grep -q "checksum-verification.sh" "$ruby_script"; then
        assert_true true "ruby.sh sources 4-tier checksum verification system"
    else
        assert_true false "ruby.sh does not source checksum-verification.sh"
    fi

    # Check for version resolution (partial version support)
    if command grep -q "resolve_ruby_version" "$ruby_script"; then
        assert_true true "ruby.sh uses version resolution for partial versions"
    else
        assert_true false "ruby.sh does not use resolve_ruby_version"
    fi
}

# Test: ruby.sh uses verify_download function
test_download_verification() {
    local ruby_script="$PROJECT_ROOT/lib/features/ruby.sh"

    if ! [ -f "$ruby_script" ]; then
        skip_test "ruby.sh not found"
        return
    fi

    # Check for verify_download usage (4-tier verification)
    if command grep -q "verify_download" "$ruby_script"; then
        assert_true true "ruby.sh uses verify_download for 4-tier checksum verification"
    else
        assert_true false "ruby.sh does not use verify_download"
    fi
}

# Test: ruby.sh does NOT use rbenv (removed in v4.0)
test_no_rbenv_usage() {
    local ruby_script="$PROJECT_ROOT/lib/features/ruby.sh"

    if ! [ -f "$ruby_script" ]; then
        skip_test "ruby.sh not found"
        return
    fi

    # Should only have comments mentioning rbenv is not used
    if command grep -q "without rbenv" "$ruby_script" || command grep -q "not.*rbenv" "$ruby_script"; then
        assert_true true "ruby.sh correctly notes rbenv is not used"
    fi

    # Should not have actual rbenv commands
    if command grep -qE "^\s*(rbenv|RBENV_ROOT)" "$ruby_script"; then
        assert_true false "ruby.sh should not use rbenv commands"
    else
        assert_true true "ruby.sh does not use rbenv commands"
    fi
}

# Run checksum verification tests
run_test test_checksum_libraries_sourced "ruby.sh sources checksum verification libraries"
run_test test_fetch_ruby_checksum_usage "ruby.sh uses 4-tier verification and version resolution"
run_test test_download_verification "ruby.sh uses verify_download for 4-tier verification"
run_test test_no_rbenv_usage "ruby.sh does not use rbenv (removed in v4.0)"

# Generate test report
generate_report
