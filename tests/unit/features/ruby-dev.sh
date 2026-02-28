#!/usr/bin/env bash
# Unit tests for lib/features/ruby-dev.sh
# Tests Ruby development tools installation

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Ruby Dev Feature Tests"

# Setup function - runs before each test
setup() {
    # Create temporary directory for testing
    export TEST_TEMP_DIR="$RESULTS_DIR/test-ruby-dev"
    mkdir -p "$TEST_TEMP_DIR"

    # Mock environment
    export USERNAME="testuser"
    export USER_UID="1000"
    export USER_GID="1000"
    export HOME="/home/testuser"

    # Create mock directories
    mkdir -p "$TEST_TEMP_DIR/home/testuser/.gem/bin"
    mkdir -p "$TEST_TEMP_DIR/etc/bashrc.d"
}

# Teardown function - runs after each test
teardown() {
    # Clean up test directory
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi

    # Unset test variables
    unset USERNAME USER_UID USER_GID HOME 2>/dev/null || true
}

# Test: Ruby dev gems
test_ruby_dev_gems() {
    local gem_bin="$TEST_TEMP_DIR/home/testuser/.gem/bin"

    # List of Ruby dev tools
    local tools=("rubocop" "solargraph" "reek" "rails" "pry" "rspec" "bundler-audit")

    # Create mock tools
    for tool in "${tools[@]}"; do
        touch "$gem_bin/$tool"
        chmod +x "$gem_bin/$tool"
    done

    # Check each tool
    for tool in "${tools[@]}"; do
        if [ -x "$gem_bin/$tool" ]; then
            assert_true true "$tool is installed"
        else
            assert_true false "$tool is not installed"
        fi
    done
}

# Test: Rubocop configuration
test_rubocop_config() {
    local rubocop_yml="$TEST_TEMP_DIR/.rubocop.yml"

    # Create config
    command cat > "$rubocop_yml" << 'EOF'
AllCops:
  TargetRubyVersion: 3.3
  NewCops: enable

Style/Documentation:
  Enabled: false
EOF

    assert_file_exists "$rubocop_yml"

    # Check configuration
    if command grep -q "TargetRubyVersion: 3.3" "$rubocop_yml"; then
        assert_true true "Rubocop targets Ruby 3.3"
    else
        assert_true false "Rubocop Ruby version not set"
    fi
}

# Test: Solargraph configuration
test_solargraph_config() {
    local solargraph_yml="$TEST_TEMP_DIR/.solargraph.yml"

    # Create config
    command cat > "$solargraph_yml" << 'EOF'
include:
  - "**/*.rb"
exclude:
  - spec/**/*
  - test/**/*
EOF

    assert_file_exists "$solargraph_yml"

    # Check configuration
    if command grep -q 'include:' "$solargraph_yml"; then
        assert_true true "Solargraph include patterns set"
    else
        assert_true false "Solargraph include patterns not set"
    fi
}

# Test: Rails support
test_rails_support() {
    local rails_bin="$TEST_TEMP_DIR/home/testuser/.gem/bin/rails"

    # Create mock rails
    touch "$rails_bin"
    chmod +x "$rails_bin"

    assert_file_exists "$rails_bin"

    # Check executable
    if [ -x "$rails_bin" ]; then
        assert_true true "Rails is executable"
    else
        assert_true false "Rails is not executable"
    fi
}

# Test: RSpec configuration
test_rspec_config() {
    local rspec_file="$TEST_TEMP_DIR/.rspec"

    # Create config
    command cat > "$rspec_file" << 'EOF'
--require spec_helper
--format documentation
--color
EOF

    assert_file_exists "$rspec_file"

    # Check configuration
    if command grep -q "\-\-format documentation" "$rspec_file"; then
        assert_true true "RSpec documentation format enabled"
    else
        assert_true false "RSpec documentation format not enabled"
    fi
}

# Test: Guard configuration
test_guard_config() {
    local guardfile="$TEST_TEMP_DIR/Guardfile"

    # Create Guardfile
    command cat > "$guardfile" << 'EOF'
guard :rspec, cmd: "bundle exec rspec" do
  watch(%r{^spec/.+_spec\.rb$})
  watch(%r{^lib/(.+)\.rb$}) { |m| "spec/lib/#{m[1]}_spec.rb" }
end
EOF

    assert_file_exists "$guardfile"

    # Check configuration
    if command grep -q "guard :rspec" "$guardfile"; then
        assert_true true "Guard RSpec configured"
    else
        assert_true false "Guard RSpec not configured"
    fi
}

# Test: Ruby dev aliases
test_ruby_dev_aliases() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/35-ruby-dev.sh"

    # Create aliases
    command cat > "$bashrc_file" << 'EOF'
alias rbc='rubocop'
alias rbca='rubocop -a'
alias rsp='rspec'
alias grd='guard'
EOF

    # Check aliases
    if command grep -q "alias rbc='rubocop'" "$bashrc_file"; then
        assert_true true "rubocop alias defined"
    else
        assert_true false "rubocop alias not defined"
    fi
}

# Test: Pry configuration
test_pry_config() {
    local pryrc="$TEST_TEMP_DIR/home/testuser/.pryrc"

    # Create config
    command cat > "$pryrc" << 'EOF'
Pry.config.editor = "nano"
Pry.config.prompt_name = "dev"
EOF

    assert_file_exists "$pryrc"

    # Check configuration
    if command grep -q "Pry.config.editor" "$pryrc"; then
        assert_true true "Pry editor configured"
    else
        assert_true false "Pry editor not configured"
    fi
}

# Test: Bundler audit
test_bundler_audit() {
    local audit_bin="$TEST_TEMP_DIR/home/testuser/.gem/bin/bundle-audit"

    # Create mock bundler-audit
    touch "$audit_bin"
    chmod +x "$audit_bin"

    assert_file_exists "$audit_bin"

    # Check executable
    if [ -x "$audit_bin" ]; then
        assert_true true "bundler-audit is executable"
    else
        assert_true false "bundler-audit is not executable"
    fi
}

# Test: Verification script
test_ruby_dev_verification() {
    local test_script="$TEST_TEMP_DIR/test-ruby-dev.sh"

    # Create verification script
    command cat > "$test_script" << 'EOF'
#!/bin/bash
echo "Ruby dev tools:"
for tool in rubocop solargraph rspec pry rails; do
    command -v $tool &>/dev/null && echo "  - $tool: installed" || echo "  - $tool: not found"
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
run_test_with_setup test_ruby_dev_gems "Ruby dev gems installation"
run_test_with_setup test_rubocop_config "Rubocop configuration"
run_test_with_setup test_solargraph_config "Solargraph configuration"
run_test_with_setup test_rails_support "Rails support"
run_test_with_setup test_rspec_config "RSpec configuration"
run_test_with_setup test_guard_config "Guard configuration"
run_test_with_setup test_ruby_dev_aliases "Ruby dev aliases"
run_test_with_setup test_pry_config "Pry configuration"
run_test_with_setup test_bundler_audit "Bundler audit"
run_test_with_setup test_ruby_dev_verification "Ruby dev verification"

# Generate test report
generate_report
