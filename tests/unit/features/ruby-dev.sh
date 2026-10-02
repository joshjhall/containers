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
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$TEST_SCRATCH_BASE/test-ruby-dev-$unique_id"
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
    command cat >"$rubocop_yml" <<'EOF'
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
    command cat >"$solargraph_yml" <<'EOF'
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
    command cat >"$rspec_file" <<'EOF'
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
    command cat >"$guardfile" <<'EOF'
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
    command cat >"$bashrc_file" <<'EOF'
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
    command cat >"$pryrc" <<'EOF'
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
    command cat >"$test_script" <<'EOF'
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

# ============================================================================
# test-ruby-dev verification script (#1001)
# ============================================================================
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/../../framework/helpers/feature-test-script.sh"
TEST_RUBY_DEV_SCRIPT="$PROJECT_ROOT/lib/features/lib/ruby/test-ruby-dev.sh"
RUBY_DEV_REQUIRED=(rspec rubocop reek brakeman yard pry rails bundle-audit)
RUBY_DEV_LSP=(solargraph)

test_ruby_dev_script_installed() {
    assert_file_exists "$TEST_RUBY_DEV_SCRIPT" "test-ruby-dev source script exists"
    # The exact call, with continuation lines joined: source path AND the
    # command name it installs as, so a wrong name or source fails here.
    local call
    call=$(command sed -e ':a' -e '/\\$/N; s/\\\n//; ta' "$PROJECT_ROOT/lib/features/ruby-dev.sh" |
        command grep -E '^install_feature_test_script ' | command tr -s ' ')
    # Anchored on the name argument's end (EOL or the next argument) so a
    # name that merely starts with test-ruby-dev cannot satisfy it.
    if command printf '%s\n' "$call" | command grep -qE \
        "^install_feature_test_script /tmp/build-scripts/features/lib/ruby/test-ruby-dev\.sh test-ruby-dev( |$)"; then
        pass_test
    else
        fail_test "ruby-dev.sh does not install lib/ruby/test-ruby-dev.sh as test-ruby-dev at top level (got: $call)"
    fi
}

test_ruby_dev_script_passes_when_all_tools_present() {
    local out
    out=$(run_feature_test_script "$TEST_RUBY_DEV_SCRIPT" true \
        "${RUBY_DEV_REQUIRED[@]}" "${RUBY_DEV_LSP[@]}")
    assert_contains "$out" "rc=0" "Exits 0 when every tool resolves"
    assert_not_contains "$out" "✗" "Reports no missing tool"
}

test_ruby_dev_script_fails_on_missing_tool() {
    local out tool
    local -a present=()
    for tool in "${RUBY_DEV_REQUIRED[@]}"; do
        [ "$tool" = "rubocop" ] || present+=("$tool")
    done
    out=$(run_feature_test_script "$TEST_RUBY_DEV_SCRIPT" true \
        "${present[@]}" "${RUBY_DEV_LSP[@]}")
    assert_contains "$out" "rc=1" "Exits 1 when a required tool is missing"
    assert_contains "$out" "✗ rubocop is not found" "Names the missing tool"
}

test_ruby_dev_script_skips_lsp_when_disabled() {
    local out
    out=$(run_feature_test_script "$TEST_RUBY_DEV_SCRIPT" false \
        "${RUBY_DEV_REQUIRED[@]}")
    assert_contains "$out" "rc=0" "Exits 0 without LSP tools when built with SKIP_LSP_INSTALL=true"
    assert_contains "$out" "skipped (built with SKIP_LSP_INSTALL=true)" "Says the LSP check was skipped"
}

test_ruby_dev_script_checks_lsp_by_default() {
    local out
    # Unsubstituted placeholder: must still check LSP (err toward more checks).
    out=$(run_feature_test_script "$TEST_RUBY_DEV_SCRIPT" keep \
        "${RUBY_DEV_REQUIRED[@]}")
    assert_contains "$out" "rc=1" "An unsubstituted placeholder still checks the LSP tools"
    assert_contains "$out" "✗ solargraph is not found" "The failure is the LSP check, not something else"
    assert_not_contains "$out" "skipped (built with SKIP_LSP_INSTALL=true)" "LSP check was not skipped"
}

# Test: the feature's own build-time decision block maps SKIP_LSP_INSTALL to
# the check_lsp value it passes to install_feature_test_script. Extracted from
# the feature and run, so a flipped or ignored condition fails here.
test_ruby_dev_feature_maps_skip_lsp() {
    local block got
    # The 5-line if/else/fi that sets TEST_RUBY_DEV_CHECK_LSP, located by its first
    # assignment (the line after the `if`).
    block=$(command awk '/^    TEST_RUBY_DEV_CHECK_LSP=false$/ { print prev; n = 4 } n > 0 { print; n-- } { prev = $0 }' \
        "$PROJECT_ROOT/lib/features/ruby-dev.sh")
    assert_contains "$block" "TEST_RUBY_DEV_CHECK_LSP=false" "Feature has a SKIP_LSP_INSTALL decision block"
    got=$(SKIP_LSP_INSTALL=true bash -c "$block; echo \"\${TEST_RUBY_DEV_CHECK_LSP}\"")
    assert_equals "false" "$got" "SKIP_LSP_INSTALL=true installs with check_lsp=false"
    got=$(SKIP_LSP_INSTALL=false bash -c "$block; echo \"\${TEST_RUBY_DEV_CHECK_LSP}\"")
    assert_equals "true" "$got" "SKIP_LSP_INSTALL=false installs with check_lsp=true"
    assert_file_contains "$PROJECT_ROOT/lib/features/ruby-dev.sh" '"${TEST_RUBY_DEV_CHECK_LSP}"' \
        "The decision is what gets passed to install_feature_test_script"
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
run_test_with_setup test_ruby_dev_script_installed "Ruby dev: test-ruby-dev is installed (#1001)"
run_test_with_setup test_ruby_dev_script_passes_when_all_tools_present "Ruby dev: test-ruby-dev exits 0 with all tools"
run_test_with_setup test_ruby_dev_script_fails_on_missing_tool "Ruby dev: test-ruby-dev exits 1 on a missing tool"
run_test_with_setup test_ruby_dev_script_skips_lsp_when_disabled "Ruby dev: test-ruby-dev skips LSP when disabled"
run_test_with_setup test_ruby_dev_script_checks_lsp_by_default "Ruby dev: test-ruby-dev checks LSP by default"
run_test_with_setup test_ruby_dev_feature_maps_skip_lsp "Ruby dev: SKIP_LSP_INSTALL maps to check_lsp (#1001)"

# Generate test report
generate_report
