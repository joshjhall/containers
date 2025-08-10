#!/bin/bash
# Kubernetes Tools - kubectl, k9s, helm, and plugin ecosystem
#
# Description:
#   Installs comprehensive Kubernetes development tools including kubectl CLI,
#   k9s terminal UI, helm package manager, and krew plugin manager with essential plugins.
#
# Features:
#   - kubectl: Official Kubernetes CLI (v1.33.x)
#   - k9s: Terminal-based Kubernetes cluster UI
#   - helm: Kubernetes package manager
#   - krew: kubectl plugin package manager
#   - Essential plugins: ctx, ns, tree, neat
#   - Auto-completion for kubectl and aliases
#   - Automatic kubeconfig detection
#
# Tools Installed:
#   - kubectl: v1.33.x from official Kubernetes apt repository
#   - k9s: v0.50.9 - Terminal UI
#   - helm: Latest version
#   - krew: v0.4.5 - Plugin manager
#
# Version Compatibility:
#   kubectl version should be within one minor version of your cluster.
#   v1.33 client works with v1.32, v1.33, and v1.34 control planes.
#
# Common Commands:
#   - kubectl get pods: List pods in current namespace
#   - kubectl apply -f: Apply configuration from file
#   - k9s: Launch terminal UI
#   - helm install: Install a helm chart
#   - kubectl krew install: Install kubectl plugins
#
# Environment Variables:
#   - KUBECONFIG: Path to kubeconfig file (default: ~/.kube/config)
#   - KUBECTL_EXTERNAL_DIFF: External diff tool for kubectl diff
#
# Note:
#   Kubeconfig from ${WORKING_DIR}/.kube/config is automatically linked if present.
#   Use 'kubectl config' commands to manage contexts and clusters.
#
set -euo pipefail

# Source standard feature header for user handling
source /tmp/build-scripts/base/feature-header.sh

# Start logging
log_feature_start "Kubernetes Tools"

# Version configuration
KUBECTL_VERSION="${KUBECTL_VERSION:-1.33}"  # Major.minor version for APT repository
K9S_VERSION="${K9S_VERSION:-0.50.9}"
KREW_VERSION="${KREW_VERSION:-0.4.5}"
HELM_VERSION="${HELM_VERSION:-latest}"  # Use "latest" or specific version like "3.16.4"

# ============================================================================
# Repository Configuration
# ============================================================================
log_message "Configuring Kubernetes repository..."

# Configure official Kubernetes apt repository
log_message "Setting up kubectl ${KUBECTL_VERSION} repository..."

log_command "Adding Kubernetes GPG key" \
    bash -c "curl -fsSL https://pkgs.k8s.io/core:/stable:/v${KUBECTL_VERSION}/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg"

log_command "Setting GPG key permissions" \
    chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

log_command "Adding Kubernetes repository" \
    bash -c "echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${KUBECTL_VERSION}/deb/ /' > /etc/apt/sources.list.d/kubernetes.list"

log_command "Updating package lists" \
    apt-get update

# ============================================================================
# kubectl Installation
# ============================================================================
log_message "Installing kubectl..."

log_command "Installing kubectl package" \
    apt-get install -y kubectl

# ============================================================================
# k9s Installation
# ============================================================================
log_message "Installing k9s ${K9S_VERSION}..."

# Detect architecture
ARCH=$(dpkg --print-architecture)
if [ "$ARCH" = "amd64" ]; then
    log_command "Downloading k9s for amd64" \
        bash -c "curl -L https://github.com/derailed/k9s/releases/download/v${K9S_VERSION}/k9s_Linux_amd64.tar.gz | tar xz -C /usr/local/bin k9s"
elif [ "$ARCH" = "arm64" ]; then
    log_command "Downloading k9s for arm64" \
        bash -c "curl -L https://github.com/derailed/k9s/releases/download/v${K9S_VERSION}/k9s_Linux_arm64.tar.gz | tar xz -C /usr/local/bin k9s"
else
    log_warning "k9s not available for architecture $ARCH, skipping..."
fi

# ============================================================================
# Helm Installation
# ============================================================================
log_message "Installing Helm..."

# Install Helm using the official installation script
log_command "Downloading and installing Helm" \
    bash -c "curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"

# Verify installation
log_command "Verifying Helm installation" \
    helm version || log_warning "Helm installation verification failed"

# ============================================================================
# Krew Plugin Manager Installation
# ============================================================================
log_message "Installing kubectl plugin manager (krew) ${KREW_VERSION}..."

# Download and install krew
log_command "Changing to temp directory" \
    cd /tmp

if [ "$ARCH" = "amd64" ]; then
    log_command "Downloading krew for amd64" \
        bash -c "curl -L https://github.com/kubernetes-sigs/krew/releases/download/v${KREW_VERSION}/krew-linux_amd64.tar.gz | tar xz"
elif [ "$ARCH" = "arm64" ]; then
    log_command "Downloading krew for arm64" \
        bash -c "curl -L https://github.com/kubernetes-sigs/krew/releases/download/v${KREW_VERSION}/krew-linux_arm64.tar.gz | tar xz"
fi

if [ -f ./krew-linux_* ]; then
    log_command "Installing krew" \
        ./krew-linux_* install krew
    log_command "Cleaning up krew installer" \
        rm -f ./krew-linux_*
fi

log_command "Returning to root directory" \
    cd /

# ============================================================================
# Environment Configuration
# ============================================================================
log_message "Configuring Kubernetes environment..."

# Ensure /etc/bashrc.d exists
log_command "Creating bashrc.d directory" \
    mkdir -p /etc/bashrc.d

# Create system-wide Kubernetes configuration
write_bashrc_content /etc/bashrc.d/65-kubernetes.sh "Kubernetes configuration" << 'KUBERNETES_BASHRC_EOF'
# ----------------------------------------------------------------------------
# Kubernetes environment configuration
# ----------------------------------------------------------------------------

# Error protection for interactive shells
set +u  # Don't error on unset variables
set +e  # Don't exit on errors

# Check if we're in an interactive shell
if [[ $- != *i* ]]; then
    # Not interactive, skip loading
    return 0
fi

# Defensive programming - check for required commands
_check_command() {
    command -v "$1" >/dev/null 2>&1
}

# ----------------------------------------------------------------------------
# Kubernetes Aliases - Common kubectl operations
# ----------------------------------------------------------------------------
alias k='kubectl'                                    # Short alias
alias kgp='kubectl get pods'                        # List pods
alias kgpa='kubectl get pods --all-namespaces'      # List all pods
alias kgs='kubectl get svc'                         # List services
alias kgd='kubectl get deployment'                  # List deployments
alias kgn='kubectl get nodes'                       # List nodes
alias kgns='kubectl get namespaces'                 # List namespaces
alias kaf='kubectl apply -f'                        # Apply config
alias kdel='kubectl delete'                         # Delete resource
alias klog='kubectl logs'                           # View logs
alias kexec='kubectl exec -it'                      # Execute in pod
alias kctx='kubectl config current-context'         # Current context
alias kns='kubectl config set-context --current --namespace'  # Set namespace
alias kdesc='kubectl describe'                      # Describe resource
alias kpf='kubectl port-forward'                    # Port forwarding

# kubectl auto-completion
if command -v kubectl &> /dev/null; then
    source <(kubectl completion bash)
    complete -F __start_kubectl k
fi

# krew PATH
export PATH="${PATH}:${HOME}/.krew/bin"

# ----------------------------------------------------------------------------
# k-logs - Stream logs from all pods matching a label
#
# Arguments:
#   $1 - Label selector (required)
#   $2 - Namespace (default: current)
#
# Example:
#   k-logs app=myapp
#   k-logs app=myapp production
# ----------------------------------------------------------------------------
k-logs() {
    if [ -z "$1" ]; then
        echo "Usage: k-logs <label-selector> [namespace]"
        return 1
    fi

    local selector="$1"
    local namespace="${2:-}"

    if [ -n "$namespace" ]; then
        kubectl logs -f -l "$selector" -n "$namespace" --all-containers=true
    else
        kubectl logs -f -l "$selector" --all-containers=true
    fi
}

# ----------------------------------------------------------------------------
# k-shell - Open shell in a pod
#
# Arguments:
#   $1 - Pod name or partial name (required)
#   $2 - Container name (optional)
#   $3 - Shell command (default: /bin/bash)
#
# Example:
#   k-shell mypod
#   k-shell mypod mycontainer
#   k-shell mypod "" /bin/sh
# ----------------------------------------------------------------------------
k-shell() {
    if [ -z "$1" ]; then
        echo "Usage: k-shell <pod-name> [container] [shell]"
        return 1
    fi

    local pod="$1"
    local container="${2:-}"
    local shell="${3:-/bin/bash}"

    # If exact pod name not found, try to find a matching pod
    if ! kubectl get pod "$pod" &>/dev/null; then
        pod=$(kubectl get pods --no-headers | grep "$pod" | head -n1 | awk '{print $1}')
        if [ -z "$pod" ]; then
            echo "No pod matching '$1' found"
            return 1
        fi
        echo "Using pod: $pod"
    fi

    if [ -n "$container" ]; then
        kubectl exec -it "$pod" -c "$container" -- "$shell" || kubectl exec -it "$pod" -c "$container" -- /bin/sh
    else
        kubectl exec -it "$pod" -- "$shell" || kubectl exec -it "$pod" -- /bin/sh
    fi
}

# ----------------------------------------------------------------------------
# k-events - Show recent events in namespace
#
# Arguments:
#   $1 - Namespace (default: current)
#
# Example:
#   k-events
#   k-events kube-system
# ----------------------------------------------------------------------------
k-events() {
    local namespace="${1:-}"

    if [ -n "$namespace" ]; then
        kubectl get events -n "$namespace" --sort-by='.lastTimestamp' | tail -20
    else
        kubectl get events --sort-by='.lastTimestamp' | tail -20
    fi
}

# ----------------------------------------------------------------------------
# k-resources - Show resource usage for nodes or pods
#
# Arguments:
#   $1 - Resource type: "nodes" or "pods" (default: pods)
#   $2 - Namespace for pods (default: current)
#
# Example:
#   k-resources
#   k-resources nodes
#   k-resources pods kube-system
# ----------------------------------------------------------------------------
k-resources() {
    local type="${1:-pods}"
    local namespace="${2:-}"

    case "$type" in
        nodes|node)
            kubectl top nodes
            ;;
        pods|pod)
            if [ -n "$namespace" ]; then
                kubectl top pods -n "$namespace"
            else
                kubectl top pods
            fi
            ;;
        *)
            echo "Usage: k-resources [nodes|pods] [namespace]"
            return 1
            ;;
    esac
}

# Clean up helper functions
unset -f _check_command 2>/dev/null || true

# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
KUBERNETES_BASHRC_EOF

log_command "Setting Kubernetes bashrc script permissions" \
    chmod +x /etc/bashrc.d/65-kubernetes.sh

# ============================================================================
# Container Startup Scripts
# ============================================================================
log_message "Creating Kubernetes startup script..."

# Create startup directory if it doesn't exist
log_command "Creating container startup directory" \
    mkdir -p /etc/container/first-startup

cat > /etc/container/first-startup/20-kubernetes-setup.sh << 'EOF'
#!/bin/bash
# Check for kubernetes config
if [ ! -f ~/.kube/config ] && [ -f ${WORKING_DIR}/.kube/config ]; then
    echo "=== Kubernetes Configuration ==="
    echo "Linking workspace kubernetes config..."
    mkdir -p ~/.kube
    ln -s ${WORKING_DIR}/.kube/config ~/.kube/config
fi

# Install useful kubectl plugins via krew if available
if command -v kubectl-krew &> /dev/null; then
    echo "Installing useful kubectl plugins..."
    kubectl krew install ctx || true
    kubectl krew install ns || true
    kubectl krew install tree || true
    kubectl krew install neat || true
fi
EOF

log_command "Setting Kubernetes startup script permissions" \
    chmod +x /etc/container/first-startup/20-kubernetes-setup.sh

# ============================================================================
# Verification Script
# ============================================================================
log_message "Creating Kubernetes verification script..."

cat > /usr/local/bin/test-kubernetes << 'EOF'
#!/bin/bash
echo "=== Kubernetes Tools Status ==="

echo ""
echo "kubectl:"
if command -v kubectl &> /dev/null; then
    echo "✓ kubectl is installed"
    echo "  Version: $(kubectl version --client --short 2>/dev/null || kubectl version --client -o yaml | grep gitVersion | head -1 | cut -d: -f2 | tr -d ' ')"
    echo "  Binary: $(which kubectl)"
else
    echo "✗ kubectl is not installed"
fi

echo ""
echo "k9s:"
if command -v k9s &> /dev/null; then
    echo "✓ k9s is installed"
    echo "  Version: $(k9s version --short 2>/dev/null || echo 'installed')"
    echo "  Binary: $(which k9s)"
else
    echo "✗ k9s is not installed"
fi

echo ""
echo "helm:"
if command -v helm &> /dev/null; then
    echo "✓ helm is installed"
    echo "  Version: $(helm version --short 2>/dev/null || echo 'installed')"
    echo "  Binary: $(which helm)"
else
    echo "✗ helm is not installed"
fi

echo ""
echo "krew:"
if [ -f "$HOME/.krew/bin/kubectl-krew" ]; then
    echo "✓ krew is installed"
    echo "  Version: $($HOME/.krew/bin/kubectl-krew version | grep GitTag | cut -d: -f2 | tr -d ' ')"
    echo "  Binary: $HOME/.krew/bin/kubectl-krew"
else
    echo "✗ krew is not installed"
fi

echo ""
echo "=== Kubeconfig Status ==="
if [ -f "$HOME/.kube/config" ]; then
    echo "✓ Kubeconfig exists at $HOME/.kube/config"
    if kubectl config current-context &>/dev/null; then
        echo "  Current context: $(kubectl config current-context)"
        echo "  Current namespace: $(kubectl config view --minify -o jsonpath='{..namespace}')"
    else
        echo "  ✗ No current context set"
    fi
else
    echo "✗ No kubeconfig found"
fi

echo ""
echo "=== Installed Plugins ==="
if [ -f "$HOME/.krew/bin/kubectl-krew" ]; then
    $HOME/.krew/bin/kubectl-krew list 2>/dev/null || echo "No plugins installed"
fi
EOF

log_command "Setting test-kubernetes permissions" \
    chmod +x /usr/local/bin/test-kubernetes

# ============================================================================
# Final Verification
# ============================================================================
log_message "Verifying Kubernetes tools installation..."

log_command "Checking kubectl version" \
    kubectl version --client || log_warning "kubectl not installed properly"

if command -v k9s &> /dev/null; then
    log_command "Checking k9s version" \
        k9s version --short || log_warning "k9s version check failed"
fi

if command -v helm &> /dev/null; then
    log_command "Checking helm version" \
        helm version --short || log_warning "helm version check failed"
fi

# End logging
log_feature_end

echo ""
echo "Kubernetes tools installation complete:"
echo "  kubectl: ${KUBECTL_VERSION} (via APT)"
echo "  k9s: ${K9S_VERSION}"
echo "  helm: $(helm version --short 2>/dev/null || echo 'installed')"
echo "  krew: ${KREW_VERSION}"
echo ""
echo "Run 'test-kubernetes' to verify installation"
echo "Run 'check-build-logs.sh kubernetes-tools' to review installation logs"
