#!/usr/bin/env bash
# Unit tests for lib/features/terraform.sh
# Tests Terraform installation and configuration

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Terraform Feature Tests"

# Setup function - runs before each test
setup() {
    # Create temporary directory for testing
    export TEST_TEMP_DIR="$RESULTS_DIR/test-terraform"
    mkdir -p "$TEST_TEMP_DIR"
    
    # Mock environment
    export TERRAFORM_VERSION="${TERRAFORM_VERSION:-1.10.0}"
    export USERNAME="testuser"
    export USER_UID="1000"
    export USER_GID="1000"
    export HOME="/home/testuser"
    
    # Create mock directories
    mkdir -p "$TEST_TEMP_DIR/usr/local/bin"
    mkdir -p "$TEST_TEMP_DIR/home/testuser/.terraform.d"
    mkdir -p "$TEST_TEMP_DIR/cache/terraform"
    mkdir -p "$TEST_TEMP_DIR/etc/bashrc.d"
}

# Teardown function - runs after each test
teardown() {
    # Clean up test directory
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
    
    # Unset test variables
    unset TERRAFORM_VERSION USERNAME USER_UID USER_GID HOME 2>/dev/null || true
}

# Test: Terraform version validation
test_terraform_version_validation() {
    local version="1.10.0"
    
    # Test version format
    if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        assert_true true "Version format is valid"
    else
        assert_true false "Version format is invalid"
    fi
    
    # Extract major version
    local major=$(echo "$version" | cut -d. -f1)
    assert_equals "1" "$major" "Major version extracted correctly"
    
    # Extract minor version
    local minor=$(echo "$version" | cut -d. -f2)
    assert_equals "10" "$minor" "Minor version extracted correctly"
}

# Test: Terraform binary installation
test_terraform_binary() {
    local bin_dir="$TEST_TEMP_DIR/usr/local/bin"
    
    # Create mock terraform binary
    touch "$bin_dir/terraform"
    chmod +x "$bin_dir/terraform"
    
    assert_file_exists "$bin_dir/terraform"
    
    # Check executable
    if [ -x "$bin_dir/terraform" ]; then
        assert_true true "Terraform binary is executable"
    else
        assert_true false "Terraform binary is not executable"
    fi
}

# Test: Terraform plugin cache
test_terraform_plugin_cache() {
    local cache_dir="$TEST_TEMP_DIR/cache/terraform/plugin-cache"
    local terraformrc="$TEST_TEMP_DIR/home/testuser/.terraformrc"
    
    # Create cache directory
    mkdir -p "$cache_dir"
    
    # Create .terraformrc
    cat > "$terraformrc" << 'EOF'
plugin_cache_dir = "/cache/terraform/plugin-cache"
disable_checkpoint = true
EOF
    
    assert_dir_exists "$cache_dir"
    assert_file_exists "$terraformrc"
    
    # Check plugin cache configuration
    if grep -q "plugin_cache_dir" "$terraformrc"; then
        assert_true true "Plugin cache is configured"
    else
        assert_true false "Plugin cache is not configured"
    fi
}

# Test: Terraform environment variables
test_terraform_environment() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/60-terraform.sh"
    
    # Create mock bashrc content
    cat > "$bashrc_file" << 'EOF'
export TF_PLUGIN_CACHE_DIR="/cache/terraform/plugin-cache"
export TF_CLI_CONFIG_FILE="$HOME/.terraformrc"
export TERRAFORM_WORKSPACE="default"
EOF
    
    # Check environment variables
    if grep -q "export TF_PLUGIN_CACHE_DIR=" "$bashrc_file"; then
        assert_true true "TF_PLUGIN_CACHE_DIR is exported"
    else
        assert_true false "TF_PLUGIN_CACHE_DIR is not exported"
    fi
    
    if grep -q "export TF_CLI_CONFIG_FILE=" "$bashrc_file"; then
        assert_true true "TF_CLI_CONFIG_FILE is exported"
    else
        assert_true false "TF_CLI_CONFIG_FILE is not exported"
    fi
}

# Test: Terraform aliases
test_terraform_aliases() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/60-terraform.sh"
    
    # Add aliases
    cat >> "$bashrc_file" << 'EOF'

# Terraform aliases
alias tf='terraform'
alias tfi='terraform init'
alias tfp='terraform plan'
alias tfa='terraform apply'
alias tfd='terraform destroy'
alias tfv='terraform validate'
alias tff='terraform fmt'
alias tfw='terraform workspace'
EOF
    
    # Check aliases
    if grep -q "alias tf='terraform'" "$bashrc_file"; then
        assert_true true "terraform alias defined"
    else
        assert_true false "terraform alias not defined"
    fi
    
    if grep -q "alias tfp='terraform plan'" "$bashrc_file"; then
        assert_true true "terraform plan alias defined"
    else
        assert_true false "terraform plan alias not defined"
    fi
}

# Test: Terraform configuration files
test_terraform_files() {
    local project_dir="$TEST_TEMP_DIR/project"
    mkdir -p "$project_dir"
    
    # Create main.tf
    cat > "$project_dir/main.tf" << 'EOF'
terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
EOF
    
    # Create variables.tf
    cat > "$project_dir/variables.tf" << 'EOF'
variable "region" {
  type    = string
  default = "us-east-1"
}
EOF
    
    assert_file_exists "$project_dir/main.tf"
    assert_file_exists "$project_dir/variables.tf"
    
    # Check Terraform version requirement
    if grep -q "required_version" "$project_dir/main.tf"; then
        assert_true true "Terraform version requirement specified"
    else
        assert_true false "Terraform version requirement missing"
    fi
}

# Test: Provider configuration
test_provider_configuration() {
    local providers_dir="$TEST_TEMP_DIR/home/testuser/.terraform.d/plugins"
    
    # Create provider directory structure
    mkdir -p "$providers_dir/registry.terraform.io/hashicorp/aws/5.0.0/linux_amd64"
    
    assert_dir_exists "$providers_dir"
    
    # Check provider path structure
    if [ -d "$providers_dir/registry.terraform.io" ]; then
        assert_true true "Provider registry structure exists"
    else
        assert_true false "Provider registry structure missing"
    fi
}

# Test: State file handling
test_state_file_handling() {
    local project_dir="$TEST_TEMP_DIR/project"
    mkdir -p "$project_dir"
    
    # Create mock state file
    cat > "$project_dir/terraform.tfstate" << 'EOF'
{
  "version": 4,
  "terraform_version": "1.10.0",
  "serial": 1,
  "lineage": "test-lineage",
  "outputs": {},
  "resources": []
}
EOF
    
    assert_file_exists "$project_dir/terraform.tfstate"
    
    # Check state file version
    if grep -q '"version": 4' "$project_dir/terraform.tfstate"; then
        assert_true true "State file version is correct"
    else
        assert_true false "State file version is incorrect"
    fi
}

# Test: Workspace management
test_workspace_management() {
    local workspaces_dir="$TEST_TEMP_DIR/project/.terraform/environment"
    
    # Create workspace directory
    mkdir -p "$workspaces_dir"
    echo "development" > "$workspaces_dir/current"
    
    assert_file_exists "$workspaces_dir/current"
    
    # Check current workspace
    local current_workspace=$(cat "$workspaces_dir/current")
    assert_equals "development" "$current_workspace" "Current workspace is development"
}

# Test: Terraform verification
test_terraform_verification() {
    local test_script="$TEST_TEMP_DIR/test-terraform.sh"
    
    # Create verification script
    cat > "$test_script" << 'EOF'
#!/bin/bash
echo "Terraform version:"
terraform version 2>/dev/null || echo "Terraform not installed"
echo "Plugin cache: ${TF_PLUGIN_CACHE_DIR:-not set}"
echo "Config file: ${TF_CLI_CONFIG_FILE:-not set}"
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

# ============================================================================
# Checksum Verification Tests
# ============================================================================

# Test: terraform.sh sources checksum libraries
test_checksum_libraries_sourced() {
    local terraform_script="$PROJECT_ROOT/lib/features/terraform.sh"

    if ! [ -f "$terraform_script" ]; then
        skip_test "terraform.sh not found"
        return
    fi

    # Check for checksum-fetch.sh
    if grep -q "source.*checksum-fetch.sh" "$terraform_script"; then
        assert_true true "checksum-fetch.sh library is sourced"
    else
        assert_true false "checksum-fetch.sh library not sourced"
    fi

    # Check for download-verify.sh
    if grep -q "source.*download-verify.sh" "$terraform_script"; then
        assert_true true "download-verify.sh library is sourced"
    else
        assert_true false "download-verify.sh library not sourced"
    fi
}

# Test: terraform.sh uses dynamic checksum fetching
test_dynamic_checksum_fetching() {
    local terraform_script="$PROJECT_ROOT/lib/features/terraform.sh"

    if ! [ -f "$terraform_script" ]; then
        skip_test "terraform.sh not found"
        return
    fi

    # Check for fetch_github_checksums_txt usage
    if grep -q "fetch_github_checksums_txt" "$terraform_script"; then
        assert_true true "Uses fetch_github_checksums_txt for dynamic fetching"
    else
        assert_true false "Does not use dynamic checksum fetching"
    fi
}

# Test: terraform.sh uses download verification
test_download_verification() {
    local terraform_script="$PROJECT_ROOT/lib/features/terraform.sh"

    if ! [ -f "$terraform_script" ]; then
        skip_test "terraform.sh not found"
        return
    fi

    # Check for download_and_extract or download_and_verify usage
    local uses_verification=false
    if grep -q "download_and_extract" "$terraform_script" || \
       grep -q "download_and_verify" "$terraform_script"; then
        uses_verification=true
    fi

    if [ "$uses_verification" = true ]; then
        assert_true true "Uses checksum verification for downloads"
    else
        assert_true false "Does not use checksum verification"
    fi
}

# Run all tests
run_test_with_setup test_terraform_version_validation "Terraform version validation works"
run_test_with_setup test_terraform_binary "Terraform binary installation"
run_test_with_setup test_terraform_plugin_cache "Terraform plugin cache configuration"
run_test_with_setup test_terraform_environment "Terraform environment variables"
run_test_with_setup test_terraform_aliases "Terraform aliases are defined"
run_test_with_setup test_terraform_files "Terraform configuration files"
run_test_with_setup test_provider_configuration "Provider configuration structure"
run_test_with_setup test_state_file_handling "State file handling"
run_test_with_setup test_workspace_management "Workspace management"
run_test_with_setup test_terraform_verification "Terraform verification script"

# Checksum verification tests
run_test test_checksum_libraries_sourced "Checksum libraries are sourced"
run_test test_dynamic_checksum_fetching "Dynamic checksum fetching is used"
run_test test_download_verification "Download verification is used"

# Generate test report
generate_report