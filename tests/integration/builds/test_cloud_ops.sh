#!/usr/bin/env bash
# Test cloud-ops container build
#
# This test verifies the cloud-ops configuration that includes:
# - Kubernetes tools (kubectl, helm, k9s)
# - Terraform and Terragrunt
# - AWS CLI
# - Google Cloud SDK
# - Cloudflare tools
# - Development tools
# - Docker CLI
# - 1Password CLI

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the test framework
source "$SCRIPT_DIR/../../framework.sh"

# Initialize the test framework
init_test_framework

# For standalone testing, we build from containers directory
export BUILD_CONTEXT="$CONTAINERS_DIR"

# Define test suite
test_suite "Cloud Ops Container Build"

# Test: Cloud ops environment builds successfully
test_cloud_ops_build() {
    local image="test-cloud-ops-$$"

    # Build with cloud-ops configuration (matches CI)
    assert_build_succeeds "Dockerfile" \
        --build-arg PROJECT_PATH=. \
        --build-arg PROJECT_NAME=test-cloud-ops \
        --build-arg INCLUDE_KUBERNETES=true \
        --build-arg INCLUDE_TERRAFORM=true \
        --build-arg INCLUDE_AWS=true \
        --build-arg INCLUDE_GCLOUD=true \
        --build-arg INCLUDE_CLOUDFLARE=true \
        --build-arg INCLUDE_DEV_TOOLS=true \
        --build-arg INCLUDE_DOCKER=true \
        --build-arg INCLUDE_OP=true \
        -t "$image"

    # Verify Kubernetes tools
    assert_executable_in_path "$image" "kubectl"
    assert_executable_in_path "$image" "helm"
    assert_executable_in_path "$image" "k9s"

    # Verify Terraform tools
    assert_executable_in_path "$image" "terraform"
    assert_executable_in_path "$image" "terragrunt"

    # Verify cloud CLIs
    assert_executable_in_path "$image" "aws"
    assert_executable_in_path "$image" "gcloud"

    # Verify Docker
    assert_executable_in_path "$image" "docker"

    # Verify dev tools
    assert_executable_in_path "$image" "git"
    assert_executable_in_path "$image" "gh"

    # Verify 1Password
    assert_executable_in_path "$image" "op"
}

# Test: Kubernetes tools show version
test_kubernetes_tools() {
    local image="test-cloud-ops-$$"

    # kubectl version
    assert_command_in_container "$image" "kubectl version --client" "Client Version"

    # helm version
    assert_command_in_container "$image" "helm version" "version"
}

# Test: Terraform shows version
test_terraform() {
    local image="test-cloud-ops-$$"

    # Terraform version
    assert_command_in_container "$image" "terraform version" "Terraform"

    # Terragrunt version
    assert_command_in_container "$image" "terragrunt --version" "terragrunt"
}

# Test: Cloud CLIs show version
test_cloud_clis() {
    local image="test-cloud-ops-$$"

    # AWS CLI
    assert_command_in_container "$image" "aws --version" "aws-cli"

    # GCloud
    assert_command_in_container "$image" "gcloud version" "Google Cloud SDK"
}

# Run all tests
run_test test_cloud_ops_build "Cloud ops environment builds successfully"
run_test test_kubernetes_tools "Kubernetes tools are functional"
run_test test_terraform "Terraform tools are functional"
run_test test_cloud_clis "Cloud CLIs are functional"

# Generate test report
generate_report
