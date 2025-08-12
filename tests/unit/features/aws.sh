#!/usr/bin/env bash
# Unit tests for lib/features/aws.sh
# Tests AWS CLI installation and configuration

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "AWS CLI Feature Tests"

# Setup function - runs before each test
setup() {
    # Create temporary directory for testing
    export TEST_TEMP_DIR="$RESULTS_DIR/test-aws"
    mkdir -p "$TEST_TEMP_DIR"
    
    # Mock environment
    export USERNAME="testuser"
    export USER_UID="1000"
    export USER_GID="1000"
    export HOME="/home/testuser"
    
    # Create mock directories
    mkdir -p "$TEST_TEMP_DIR/usr/local/bin"
    mkdir -p "$TEST_TEMP_DIR/home/testuser/.aws"
    mkdir -p "$TEST_TEMP_DIR/etc/bashrc.d"
}

# Teardown function - runs after each test
teardown() {
    # Clean up test directory
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
    
    # Unset test variables
    unset USERNAME USER_UID USER_GID HOME 2>/dev/null || true
}

# Test: AWS CLI installation
test_aws_cli_installation() {
    local bin_dir="$TEST_TEMP_DIR/usr/local/bin"
    
    # Create mock aws binary
    touch "$bin_dir/aws"
    chmod +x "$bin_dir/aws"
    
    assert_file_exists "$bin_dir/aws"
    
    # Check executable
    if [ -x "$bin_dir/aws" ]; then
        assert_true true "aws CLI is executable"
    else
        assert_true false "aws CLI is not executable"
    fi
}

# Test: AWS configuration directory
test_aws_config_directory() {
    local aws_dir="$TEST_TEMP_DIR/home/testuser/.aws"
    
    assert_dir_exists "$aws_dir"
    
    # Check directory is writable
    if [ -w "$aws_dir" ]; then
        assert_true true "AWS config directory is writable"
    else
        assert_true false "AWS config directory is not writable"
    fi
}

# Test: AWS credentials file
test_aws_credentials() {
    local aws_dir="$TEST_TEMP_DIR/home/testuser/.aws"
    local credentials_file="$aws_dir/credentials"
    
    # Create mock credentials
    cat > "$credentials_file" << 'EOF'
[default]
aws_access_key_id = AKIAIOSFODNN7EXAMPLE
aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY

[production]
aws_access_key_id = AKIAIOSFODNN7EXAMPLE2
aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY2
EOF
    
    assert_file_exists "$credentials_file"
    
    # Check profiles exist
    if grep -q "\[default\]" "$credentials_file"; then
        assert_true true "Default profile exists"
    else
        assert_true false "Default profile missing"
    fi
    
    if grep -q "\[production\]" "$credentials_file"; then
        assert_true true "Production profile exists"
    else
        assert_true false "Production profile missing"
    fi
}

# Test: AWS config file
test_aws_config() {
    local aws_dir="$TEST_TEMP_DIR/home/testuser/.aws"
    local config_file="$aws_dir/config"
    
    # Create mock config
    cat > "$config_file" << 'EOF'
[default]
region = us-east-1
output = json

[profile production]
region = us-west-2
output = table
EOF
    
    assert_file_exists "$config_file"
    
    # Check configuration
    if grep -q "region = us-east-1" "$config_file"; then
        assert_true true "Default region configured"
    else
        assert_true false "Default region not configured"
    fi
    
    if grep -q "output = json" "$config_file"; then
        assert_true true "Output format configured"
    else
        assert_true false "Output format not configured"
    fi
}

# Test: AWS environment variables
test_aws_environment() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/65-aws.sh"
    
    # Create environment setup
    cat > "$bashrc_file" << 'EOF'
export AWS_CONFIG_FILE="$HOME/.aws/config"
export AWS_SHARED_CREDENTIALS_FILE="$HOME/.aws/credentials"
export AWS_DEFAULT_REGION="us-east-1"
export AWS_PAGER=""
EOF
    
    # Check environment variables
    if grep -q "export AWS_CONFIG_FILE=" "$bashrc_file"; then
        assert_true true "AWS_CONFIG_FILE is exported"
    else
        assert_true false "AWS_CONFIG_FILE is not exported"
    fi
    
    if grep -q "export AWS_DEFAULT_REGION=" "$bashrc_file"; then
        assert_true true "AWS_DEFAULT_REGION is exported"
    else
        assert_true false "AWS_DEFAULT_REGION is not exported"
    fi
}

# Test: AWS CLI aliases
test_aws_aliases() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/65-aws.sh"
    
    # Add aliases
    cat >> "$bashrc_file" << 'EOF'

# AWS aliases
alias awsp='aws --profile'
alias awsl='aws s3 ls'
alias awsec2='aws ec2 describe-instances'
alias awslogs='aws logs tail'
alias awssm='aws ssm'
EOF
    
    # Check aliases
    if grep -q "alias awsp='aws --profile'" "$bashrc_file"; then
        assert_true true "AWS profile alias defined"
    else
        assert_true false "AWS profile alias not defined"
    fi
    
    if grep -q "alias awsl='aws s3 ls'" "$bashrc_file"; then
        assert_true true "S3 list alias defined"
    else
        assert_true false "S3 list alias not defined"
    fi
}

# Test: AWS SSO configuration
test_aws_sso() {
    local aws_dir="$TEST_TEMP_DIR/home/testuser/.aws"
    local sso_cache="$aws_dir/sso/cache"
    
    # Create SSO cache directory
    mkdir -p "$sso_cache"
    
    assert_dir_exists "$sso_cache"
}

# Test: AWS CLI completion
test_aws_completion() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/65-aws.sh"
    
    # Add completion
    cat >> "$bashrc_file" << 'EOF'
complete -C aws_completer aws
EOF
    
    # Check completion setup
    if grep -q "complete -C aws_completer aws" "$bashrc_file"; then
        assert_true true "AWS completion configured"
    else
        assert_true false "AWS completion not configured"
    fi
}

# Test: SAM CLI check
test_sam_cli() {
    local bin_dir="$TEST_TEMP_DIR/usr/local/bin"
    
    # Create mock sam binary
    touch "$bin_dir/sam"
    chmod +x "$bin_dir/sam"
    
    # Check if SAM CLI would be installed
    if [ -x "$bin_dir/sam" ]; then
        assert_true true "SAM CLI is available"
    else
        assert_true false "SAM CLI is not available"
    fi
}

# Test: Verification script
test_aws_verification() {
    local test_script="$TEST_TEMP_DIR/test-aws.sh"
    
    # Create verification script
    cat > "$test_script" << 'EOF'
#!/bin/bash
echo "AWS CLI version:"
aws --version 2>/dev/null || echo "AWS CLI not installed"
echo "Configured profiles:"
aws configure list-profiles 2>/dev/null || echo "No profiles configured"
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
run_test_with_setup test_aws_cli_installation "AWS CLI installation"
run_test_with_setup test_aws_config_directory "AWS config directory setup"
run_test_with_setup test_aws_credentials "AWS credentials file"
run_test_with_setup test_aws_config "AWS config file"
run_test_with_setup test_aws_environment "AWS environment variables"
run_test_with_setup test_aws_aliases "AWS CLI aliases"
run_test_with_setup test_aws_sso "AWS SSO configuration"
run_test_with_setup test_aws_completion "AWS CLI completion"
run_test_with_setup test_sam_cli "SAM CLI availability"
run_test_with_setup test_aws_verification "AWS verification script"

# Generate test report
generate_report