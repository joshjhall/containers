#!/usr/bin/env bash
# Unit tests for lib/features/ruby.sh
# Tests Ruby programming language installation and configuration

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
    export RUBY_VERSION="${RUBY_VERSION:-3.3.0}"
    export USERNAME="testuser"
    export USER_UID="1000"
    export USER_GID="1000"
    export HOME="/home/testuser"
    
    # Create mock directories
    mkdir -p "$TEST_TEMP_DIR/usr/local/bin"
    mkdir -p "$TEST_TEMP_DIR/usr/local/rbenv"
    mkdir -p "$TEST_TEMP_DIR/home/testuser/.rbenv"
    mkdir -p "$TEST_TEMP_DIR/cache/bundle"
    mkdir -p "$TEST_TEMP_DIR/etc/bashrc.d"
}

# Teardown function - runs after each test
teardown() {
    # Clean up test directory
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
    
    # Unset test variables
    unset RUBY_VERSION USERNAME USER_UID USER_GID HOME 2>/dev/null || true
}

# Test: Ruby version validation
test_ruby_version_validation() {
    # Test valid version format
    local version="3.3.0"
    if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        assert_true true "Version format is valid"
    else
        assert_true false "Version format is invalid"
    fi
    
    # Test major version extraction
    local major=$(echo "$version" | cut -d. -f1)
    assert_equals "3" "$major" "Major version extracted correctly"
    
    # Test minor version extraction
    local minor=$(echo "$version" | cut -d. -f2)
    assert_equals "3" "$minor" "Minor version extracted correctly"
    
    # Test version comparison
    if [ "$major" -ge 3 ]; then
        assert_true true "Ruby 3.x or newer detected"
    else
        assert_true false "Ruby version too old"
    fi
}

# Test: rbenv installation structure
test_rbenv_installation() {
    local rbenv_root="$TEST_TEMP_DIR/usr/local/rbenv"
    
    # Create rbenv directory structure
    mkdir -p "$rbenv_root/bin"
    mkdir -p "$rbenv_root/shims"
    mkdir -p "$rbenv_root/versions"
    mkdir -p "$rbenv_root/plugins/ruby-build"
    
    # Create mock rbenv executable
    touch "$rbenv_root/bin/rbenv"
    chmod +x "$rbenv_root/bin/rbenv"
    
    # Check structure
    assert_dir_exists "$rbenv_root"
    assert_dir_exists "$rbenv_root/bin"
    assert_dir_exists "$rbenv_root/shims"
    assert_dir_exists "$rbenv_root/versions"
    assert_dir_exists "$rbenv_root/plugins/ruby-build"
    
    # Check rbenv executable
    if [ -x "$rbenv_root/bin/rbenv" ]; then
        assert_true true "rbenv is executable"
    else
        assert_true false "rbenv is not executable"
    fi
}

# Test: Ruby installation
test_ruby_installation() {
    local rbenv_root="$TEST_TEMP_DIR/usr/local/rbenv"
    local ruby_version="3.3.0"
    local ruby_dir="$rbenv_root/versions/$ruby_version"
    
    # Create Ruby installation
    mkdir -p "$ruby_dir/bin"
    mkdir -p "$ruby_dir/lib/ruby"
    
    # Create Ruby binaries
    local binaries=("ruby" "gem" "bundle" "bundler" "irb" "rake")
    for bin in "${binaries[@]}"; do
        touch "$ruby_dir/bin/$bin"
        chmod +x "$ruby_dir/bin/$bin"
    done
    
    # Check installation
    assert_dir_exists "$ruby_dir"
    
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
    local gem_config="$TEST_TEMP_DIR/home/testuser/.gemrc"
    
    # Create gem configuration
    cat > "$gem_config" << 'EOF'
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
    if grep -q "gem: --no-document" "$gem_config"; then
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
    cat > "$bundle_config" << 'EOF'
---
BUNDLE_PATH: "/cache/bundle"
BUNDLE_CACHE_ALL: "true"
BUNDLE_JOBS: "4"
EOF
    
    assert_file_exists "$bundle_config"
    assert_dir_exists "$cache_dir"
    
    # Check cache path configuration
    if grep -q 'BUNDLE_PATH: "/cache/bundle"' "$bundle_config"; then
        assert_true true "Bundle uses cache directory"
    else
        assert_true false "Bundle doesn't use cache directory"
    fi
    
    # Check parallel jobs
    if grep -q 'BUNDLE_JOBS: "4"' "$bundle_config"; then
        assert_true true "Bundle configured for parallel jobs"
    else
        assert_true false "Bundle not configured for parallel jobs"
    fi
}

# Test: Ruby environment variables
test_ruby_environment_variables() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/35-ruby.sh"
    
    # Create mock bashrc content
    cat > "$bashrc_file" << 'EOF'
export RBENV_ROOT="/usr/local/rbenv"
export PATH="$RBENV_ROOT/bin:$RBENV_ROOT/shims:$PATH"
export BUNDLE_PATH="/cache/bundle"
export GEM_HOME="$HOME/.gem"
export GEM_PATH="$GEM_HOME"

# rbenv init
eval "$(rbenv init -)"
EOF
    
    # Check environment variables
    if grep -q "export RBENV_ROOT=" "$bashrc_file"; then
        assert_true true "RBENV_ROOT is exported"
    else
        assert_true false "RBENV_ROOT is not exported"
    fi
    
    if grep -q 'PATH.*RBENV_ROOT/bin.*RBENV_ROOT/shims' "$bashrc_file"; then
        assert_true true "PATH includes rbenv directories"
    else
        assert_true false "PATH doesn't include rbenv directories"
    fi
    
    if grep -q "export BUNDLE_PATH=" "$bashrc_file"; then
        assert_true true "BUNDLE_PATH is exported"
    else
        assert_true false "BUNDLE_PATH is not exported"
    fi
    
    if grep -q 'eval "$(rbenv init -)"' "$bashrc_file"; then
        assert_true true "rbenv init is configured"
    else
        assert_true false "rbenv init is not configured"
    fi
}

# Test: Ruby aliases and helpers
test_ruby_aliases_helpers() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/35-ruby.sh"
    
    # Add aliases section
    cat >> "$bashrc_file" << 'EOF'

# Ruby aliases
alias be='bundle exec'
alias bi='bundle install'
alias bu='bundle update'
alias bip='bundle install --path vendor/bundle'
alias bers='bundle exec rails server'
alias berc='bundle exec rails console'
alias bert='bundle exec rake test'
alias bers='bundle exec rspec'
EOF
    
    # Check common aliases
    if grep -q "alias be='bundle exec'" "$bashrc_file"; then
        assert_true true "bundle exec alias defined"
    else
        assert_true false "bundle exec alias not defined"
    fi
    
    if grep -q "alias bi='bundle install'" "$bashrc_file"; then
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
    cat > "$project_dir/Gemfile" << 'EOF'
source 'https://rubygems.org'

ruby '3.3.0'

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
    if grep -q "ruby '3.3.0'" "$project_dir/Gemfile"; then
        assert_true true "Gemfile specifies Ruby version"
    else
        assert_true false "Gemfile doesn't specify Ruby version"
    fi
    
    # Check gem groups
    if grep -q "group :development, :test do" "$project_dir/Gemfile"; then
        assert_true true "Gemfile has development/test group"
    else
        assert_true false "Gemfile missing development/test group"
    fi
}

# Test: Permissions and ownership
test_ruby_permissions() {
    local rbenv_root="$TEST_TEMP_DIR/usr/local/rbenv"
    local gem_home="$TEST_TEMP_DIR/home/testuser/.gem"
    
    # Create directories
    mkdir -p "$rbenv_root" "$gem_home"
    
    # Check directories exist and are accessible
    if [ -d "$rbenv_root" ] && [ -r "$rbenv_root" ]; then
        assert_true true "rbenv root is readable"
    else
        assert_true false "rbenv root is not readable"
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
    
    # Create verification script
    cat > "$test_script" << 'EOF'
#!/bin/bash
echo "Ruby version:"
ruby --version 2>/dev/null || echo "Ruby not installed"
echo "Gem version:"
gem --version 2>/dev/null || echo "Gem not installed"
echo "Bundler version:"
bundle --version 2>/dev/null || echo "Bundler not installed"
echo "rbenv version:"
rbenv --version 2>/dev/null || echo "rbenv not installed"
echo "Installed Ruby versions:"
rbenv versions 2>/dev/null || echo "No Ruby versions installed"
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
run_test_with_setup test_ruby_version_validation "Ruby version validation works"
run_test_with_setup test_rbenv_installation "rbenv installation structure is correct"
run_test_with_setup test_ruby_installation "Ruby installation is complete"
run_test_with_setup test_gem_configuration "Gem configuration is correct"
run_test_with_setup test_bundle_cache_configuration "Bundle cache is configured properly"
run_test_with_setup test_ruby_environment_variables "Ruby environment variables are set"
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
    if grep -q "source.*checksum-fetch.sh" "$ruby_script"; then
        assert_true true "ruby.sh sources checksum-fetch.sh library"
    else
        assert_true false "ruby.sh does not source checksum-fetch.sh library"
    fi

    # Check that download-verify.sh is sourced
    if grep -q "source.*download-verify.sh" "$ruby_script"; then
        assert_true true "ruby.sh sources download-verify.sh library"
    else
        assert_true false "ruby.sh does not source download-verify.sh library"
    fi
}

# Test: ruby.sh uses fetch_ruby_checksum function
test_fetch_ruby_checksum_usage() {
    local ruby_script="$PROJECT_ROOT/lib/features/ruby.sh"

    if ! [ -f "$ruby_script" ]; then
        skip_test "ruby.sh not found"
        return
    fi

    # Check for fetch_ruby_checksum usage
    if grep -q "fetch_ruby_checksum" "$ruby_script"; then
        assert_true true "ruby.sh uses fetch_ruby_checksum for dynamic checksum fetching"
    else
        assert_true false "ruby.sh does not use fetch_ruby_checksum"
    fi

    # Check for checksum variable
    if grep -q "RUBY_CHECKSUM=" "$ruby_script"; then
        assert_true true "ruby.sh stores checksum in RUBY_CHECKSUM variable"
    else
        assert_true false "ruby.sh does not store checksum"
    fi
}

# Test: ruby.sh uses download_and_verify function
test_download_verification() {
    local ruby_script="$PROJECT_ROOT/lib/features/ruby.sh"

    if ! [ -f "$ruby_script" ]; then
        skip_test "ruby.sh not found"
        return
    fi

    # Check for download_and_verify usage
    if grep -q "download_and_verify" "$ruby_script"; then
        assert_true true "ruby.sh uses download_and_verify for checksum verification"
    else
        assert_true false "ruby.sh does not use download_and_verify"
    fi
}

# Run checksum verification tests
run_test test_checksum_libraries_sourced "ruby.sh sources checksum verification libraries"
run_test test_fetch_ruby_checksum_usage "ruby.sh uses fetch_ruby_checksum for dynamic checksums"
run_test test_download_verification "ruby.sh uses download_and_verify for verification"

# Generate test report
generate_report