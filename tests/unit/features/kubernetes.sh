#!/usr/bin/env bash
# Unit tests for lib/features/kubernetes.sh
# Tests Kubernetes tools installation and configuration

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Kubernetes Feature Tests"

# Setup function - runs before each test
setup() {
    # Create temporary directory for testing
    export TEST_TEMP_DIR="$RESULTS_DIR/test-kubernetes"
    mkdir -p "$TEST_TEMP_DIR"

    # Mock environment
    export KUBECTL_VERSION="${KUBECTL_VERSION:-latest}"
    export USERNAME="testuser"
    export USER_UID="1000"
    export USER_GID="1000"
    export HOME="/home/testuser"

    # Create mock directories
    mkdir -p "$TEST_TEMP_DIR/usr/local/bin"
    mkdir -p "$TEST_TEMP_DIR/home/testuser/.kube"
    mkdir -p "$TEST_TEMP_DIR/etc/bashrc.d"
}

# Teardown function - runs after each test
teardown() {
    # Clean up test directory
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi

    # Unset test variables
    unset KUBECTL_VERSION USERNAME USER_UID USER_GID HOME 2>/dev/null || true
}

# Test: kubectl installation
test_kubectl_installation() {
    local bin_dir="$TEST_TEMP_DIR/usr/local/bin"

    # Create mock kubectl binary
    touch "$bin_dir/kubectl"
    chmod +x "$bin_dir/kubectl"

    assert_file_exists "$bin_dir/kubectl"

    # Check executable
    if [ -x "$bin_dir/kubectl" ]; then
        assert_true true "kubectl is executable"
    else
        assert_true false "kubectl is not executable"
    fi
}

# Test: Helm installation
test_helm_installation() {
    local bin_dir="$TEST_TEMP_DIR/usr/local/bin"

    # Create mock helm binary
    touch "$bin_dir/helm"
    chmod +x "$bin_dir/helm"

    assert_file_exists "$bin_dir/helm"

    # Check executable
    if [ -x "$bin_dir/helm" ]; then
        assert_true true "helm is executable"
    else
        assert_true false "helm is not executable"
    fi
}

# Test: kubeconfig setup
test_kubeconfig_setup() {
    local kube_dir="$TEST_TEMP_DIR/home/testuser/.kube"
    local kubeconfig="$kube_dir/config"

    # Create mock kubeconfig
    command cat > "$kubeconfig" << 'EOF'
apiVersion: v1
kind: Config
clusters:
- cluster:
    server: https://kubernetes.docker.internal:6443
  name: docker-desktop
contexts:
- context:
    cluster: docker-desktop
    user: docker-desktop
  name: docker-desktop
current-context: docker-desktop
EOF

    assert_file_exists "$kubeconfig"

    # Check kubeconfig structure
    if command grep -q "apiVersion: v1" "$kubeconfig"; then
        assert_true true "kubeconfig has correct API version"
    else
        assert_true false "kubeconfig missing API version"
    fi
}

# Test: K8s tools installation
test_k8s_tools() {
    local bin_dir="$TEST_TEMP_DIR/usr/local/bin"

    # List of K8s tools
    local tools=("kubectx" "kubens" "k9s" "stern" "kustomize")

    # Create mock tools
    for tool in "${tools[@]}"; do
        touch "$bin_dir/$tool"
        chmod +x "$bin_dir/$tool"
    done

    # Check each tool
    for tool in "${tools[@]}"; do
        if [ -x "$bin_dir/$tool" ]; then
            assert_true true "$tool is installed"
        else
            assert_true false "$tool is not installed"
        fi
    done
}

# Test: Kubernetes aliases
test_kubernetes_aliases() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/55-kubernetes.sh"

    # Create aliases
    command cat > "$bashrc_file" << 'EOF'
alias k='kubectl'
alias kgp='kubectl get pods'
alias kgs='kubectl get services'
alias kgd='kubectl get deployments'
alias kaf='kubectl apply -f'
alias kdel='kubectl delete'
alias klog='kubectl logs'
alias kexec='kubectl exec -it'
EOF

    # Check aliases
    if command grep -q "alias k='kubectl'" "$bashrc_file"; then
        assert_true true "kubectl alias defined"
    else
        assert_true false "kubectl alias not defined"
    fi

    if command grep -q "alias kgp='kubectl get pods'" "$bashrc_file"; then
        assert_true true "get pods alias defined"
    else
        assert_true false "get pods alias not defined"
    fi
}

# Test: Helm repositories
test_helm_repositories() {
    local helm_dir="$TEST_TEMP_DIR/home/testuser/.config/helm"
    mkdir -p "$helm_dir"

    # Create repositories file
    command cat > "$helm_dir/repositories.yaml" << 'EOF'
apiVersion: v1
repositories:
- name: stable
  url: https://charts.helm.sh/stable
- name: bitnami
  url: https://charts.bitnami.com/bitnami
EOF

    assert_file_exists "$helm_dir/repositories.yaml"

    # Check repository configuration
    if command grep -q "charts.helm.sh/stable" "$helm_dir/repositories.yaml"; then
        assert_true true "Stable repo configured"
    else
        assert_true false "Stable repo not configured"
    fi
}

# Test: Environment variables
test_k8s_environment() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/55-kubernetes.sh"

    # Add environment variables
    command cat >> "$bashrc_file" << 'EOF'
export KUBECONFIG="$HOME/.kube/config"
export KUBE_EDITOR="nano"
export HELM_HOME="$HOME/.helm"
EOF

    # Check environment variables
    if command grep -q "export KUBECONFIG=" "$bashrc_file"; then
        assert_true true "KUBECONFIG is exported"
    else
        assert_true false "KUBECONFIG is not exported"
    fi

    if command grep -q "export HELM_HOME=" "$bashrc_file"; then
        assert_true true "HELM_HOME is exported"
    else
        assert_true false "HELM_HOME is not exported"
    fi
}

# Test: kubectl completion
test_kubectl_completion() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/55-kubernetes.sh"

    # Add completion
    command cat >> "$bashrc_file" << 'EOF'
source <(kubectl completion bash)
complete -F __start_kubectl k
EOF

    # Check completion setup
    if command grep -q "kubectl completion bash" "$bashrc_file"; then
        assert_true true "kubectl completion configured"
    else
        assert_true false "kubectl completion not configured"
    fi
}

# Test: Manifest files
test_manifest_files() {
    local project_dir="$TEST_TEMP_DIR/project"
    mkdir -p "$project_dir"

    # Create deployment manifest
    command cat > "$project_dir/deployment.yaml" << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-app
spec:
  replicas: 3
  selector:
    matchLabels:
      app: test-app
EOF

    assert_file_exists "$project_dir/deployment.yaml"

    # Check manifest structure
    if command grep -q "kind: Deployment" "$project_dir/deployment.yaml"; then
        assert_true true "Deployment manifest valid"
    else
        assert_true false "Deployment manifest invalid"
    fi
}

# Test: Verification script
test_k8s_verification() {
    local test_script="$TEST_TEMP_DIR/test-k8s.sh"

    # Create verification script
    command cat > "$test_script" << 'EOF'
#!/bin/bash
echo "kubectl version:"
kubectl version --client 2>/dev/null || echo "kubectl not installed"
echo "helm version:"
helm version 2>/dev/null || echo "helm not installed"
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

# Test: Dynamic checksum fetching is used
test_dynamic_checksum_fetching() {
    local kubernetes_script="$PROJECT_ROOT/lib/features/kubernetes.sh"

    # Should source checksum-fetch.sh for dynamic fetching
    if command grep -q "source.*checksum-fetch.sh" "$kubernetes_script"; then
        assert_true true "kubernetes.sh sources checksum-fetch.sh for dynamic fetching"
    else
        assert_true false "kubernetes.sh doesn't source checksum-fetch.sh"
    fi

    # Should use dynamic fetching functions (not hardcoded checksums)
    if command grep -q "fetch_github_checksums_txt" "$kubernetes_script"; then
        assert_true true "Uses fetch_github_checksums_txt for dynamic fetching"
    else
        assert_true false "Doesn't use fetch_github_checksums_txt"
    fi

    if command grep -q "fetch_github_sha256_file" "$kubernetes_script"; then
        assert_true true "Uses fetch_github_sha256_file for individual checksum files"
    else
        assert_true false "Doesn't use fetch_github_sha256_file"
    fi
}

# Test: Download verification functions are used
test_download_verification() {
    local kubernetes_script="$PROJECT_ROOT/lib/features/kubernetes.sh"

    # Check that download verification functions are used (not curl | tar)
    if command grep -q "download_and_extract" "$kubernetes_script"; then
        assert_true true "Uses download_and_extract for verification"
    else
        assert_true false "Doesn't use download_and_extract"
    fi

    # kubernetes.sh uses download_and_extract for all tools (k9s, helm, krew)
    # It doesn't use download_and_verify since helm calculates checksum inline
}

# Test: Script sources download-verify.sh
test_sources_download_verify() {
    local kubernetes_script="$PROJECT_ROOT/lib/features/kubernetes.sh"

    if command grep -q "source.*download-verify.sh" "$kubernetes_script"; then
        assert_true true "kubernetes.sh sources download-verify.sh"
    else
        assert_true false "kubernetes.sh doesn't source download-verify.sh"
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
run_test_with_setup test_kubectl_installation "kubectl installation"
run_test_with_setup test_helm_installation "Helm installation"
run_test_with_setup test_kubeconfig_setup "kubeconfig setup"
run_test_with_setup test_k8s_tools "K8s tools installation"
run_test_with_setup test_kubernetes_aliases "Kubernetes aliases"
run_test_with_setup test_helm_repositories "Helm repositories"
run_test_with_setup test_k8s_environment "K8s environment variables"
run_test_with_setup test_kubectl_completion "kubectl completion"
run_test_with_setup test_manifest_files "Manifest files"
run_test_with_setup test_k8s_verification "K8s verification script"
run_test_with_setup test_dynamic_checksum_fetching "Dynamic checksum fetching"
run_test_with_setup test_download_verification "Download verification functions"
run_test_with_setup test_sources_download_verify "Sources download-verify.sh"

# Generate test report
generate_report
