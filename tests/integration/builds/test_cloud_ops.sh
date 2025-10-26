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
    # Use pre-built image if provided, otherwise build locally
    if [ -n "${IMAGE_TO_TEST:-}" ]; then
        local image="$IMAGE_TO_TEST"
        echo "Testing pre-built image: $image"
    else
        local image="test-cloud-ops-$$"
        echo "Building image locally: $image"

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
    fi

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
    local image="${IMAGE_TO_TEST:-test-cloud-ops-$$}"

    # kubectl version
    assert_command_in_container "$image" "kubectl version --client" "Client Version"

    # helm version
    assert_command_in_container "$image" "helm version" "version"
}

# Test: Terraform shows version
test_terraform() {
    local image="${IMAGE_TO_TEST:-test-cloud-ops-$$}"

    # Terraform version
    assert_command_in_container "$image" "terraform version" "Terraform"

    # Terragrunt version
    assert_command_in_container "$image" "terragrunt --version" "terragrunt"
}

# Test: Cloud CLIs show version
test_cloud_clis() {
    local image="${IMAGE_TO_TEST:-test-cloud-ops-$$}"

    # AWS CLI
    assert_command_in_container "$image" "aws --version" "aws-cli"

    # GCloud
    assert_command_in_container "$image" "gcloud version" "Google Cloud SDK"
}

# Test: Terraform can validate configurations
test_terraform_functionality() {
    local image="${IMAGE_TO_TEST:-test-cloud-ops-$$}"

    # Create a simple Terraform config and validate it
    assert_command_in_container "$image" "cd /tmp && echo 'terraform { required_version = \">= 1.0\" }' > main.tf && terraform init && terraform validate" "Success"
}

# Test: Helm can work with charts
test_helm_functionality() {
    local image="${IMAGE_TO_TEST:-test-cloud-ops-$$}"

    # Helm can search repos
    assert_command_in_container "$image" "helm version --short" "v"

    # Helm can create a chart
    assert_command_in_container "$image" "cd /tmp && helm create test-chart && test -d test-chart && echo ok" "ok"
}

# Test: kubectl can work with manifests
test_kubectl_functionality() {
    local image="${IMAGE_TO_TEST:-test-cloud-ops-$$}"

    # kubectl can validate a manifest (dry-run without cluster)
    # Use KUBECONFIG=/dev/null to prevent kubectl from using default localhost:8080
    assert_command_in_container "$image" "echo 'apiVersion: v1
kind: ConfigMap
metadata:
  name: test-config
data:
  key: value' | KUBECONFIG=/dev/null kubectl create --dry-run=client -o yaml -f - | grep -q 'kind: ConfigMap' && echo ok" "ok"
}

# Test: Cache directories configured
test_cloud_cache() {
    local image="${IMAGE_TO_TEST:-test-cloud-ops-$$}"

    # Verify common cache directories exist and are writable
    assert_command_in_container "$image" "test -w /cache && echo writable" "writable"
}

# Run all tests
run_test test_cloud_ops_build "Cloud ops environment builds successfully"
run_test test_kubernetes_tools "Kubernetes tools are functional"
run_test test_terraform "Terraform tools are functional"
run_test test_cloud_clis "Cloud CLIs are functional"
run_test test_terraform_functionality "Terraform can validate configurations"
run_test test_helm_functionality "Helm can work with charts"
run_test test_kubectl_functionality "kubectl can validate manifests"
run_test test_cloud_cache "Cache directories are configured"

# Generate test report
generate_report
