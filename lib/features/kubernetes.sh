#!/bin/bash
# Kubernetes Tools - kubectl, k9s, helm, and plugin ecosystem
#
# Description:
#   Installs comprehensive Kubernetes development tools including kubectl CLI,
#   k9s terminal UI, helm package manager, and krew plugin manager with essential plugins.
#
# Features:
#   - kubectl: Official Kubernetes CLI
#   - k9s: Terminal-based Kubernetes cluster UI
#   - helm: Kubernetes package manager
#   - krew: kubectl plugin package manager
#   - Essential plugins: ctx, ns, tree, neat
#   - Auto-completion for kubectl and aliases
#   - Automatic kubeconfig detection
#
# Tools Installed:
#   - kubectl: From official Kubernetes apt repository
#   - k9s: Terminal UI for Kubernetes
#   - helm: Latest version
#   - krew: Plugin manager for kubectl
#
# Version Compatibility:
#   kubectl version should be within one minor version of your cluster.
#   The installed client version will work with clusters one version newer or older.
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

# Source apt utilities for reliable package installation
source /tmp/build-scripts/base/apt-utils.sh

# Source download verification utilities for secure binary downloads
source /tmp/build-scripts/base/download-verify.sh

# Source checksum fetching utilities for dynamic checksum retrieval
source /tmp/build-scripts/features/lib/checksum-fetch.sh

# Source secure temp directory utilities

# Start logging
log_feature_start "Kubernetes Tools"

# Version configuration
KUBECTL_VERSION="${KUBECTL_VERSION:-1.33}"  # Can be major.minor or major.minor.patch
K9S_VERSION="${K9S_VERSION:-0.50.16}"
KREW_VERSION="${KREW_VERSION:-0.4.5}"
HELM_VERSION="${HELM_VERSION:-3.19.0}"

# Extract major.minor version from KUBECTL_VERSION for repository URL
# This handles both "1.31" and "1.31.0" formats
KUBECTL_MINOR_VERSION=$(echo "$KUBECTL_VERSION" | cut -d. -f1,2)

# ============================================================================
# Repository Configuration
# ============================================================================
log_message "Configuring Kubernetes repository..."

# Configure official Kubernetes apt repository
# Support both old (apt-key) and new (signed-by) methods for backwards compatibility
# - Debian 11 (Bullseye) and 12 (Bookworm): apt-key still available
# - Debian 13 (Trixie) and later: apt-key removed, use signed-by method

log_message "Setting up kubectl repository..."

if command -v apt-key >/dev/null 2>&1; then
    # Old method for Debian 11/12 compatibility
    log_message "Using apt-key method (Debian 11/12)"
    log_command "Adding Kubernetes GPG key" \
        bash -c "curl -fsSL https://pkgs.k8s.io/core:/stable:/v${KUBECTL_MINOR_VERSION}/deb/Release.key | apt-key add -"

    log_command "Adding Kubernetes repository" \
        bash -c "echo 'deb https://pkgs.k8s.io/core:/stable:/v${KUBECTL_MINOR_VERSION}/deb/ /' > /etc/apt/sources.list.d/kubernetes.list"
else
    # New method for Debian 13+ (Trixie and later)
    log_message "Using signed-by method (Debian 13+)"
    log_command "Creating keyrings directory" \
        mkdir -p /etc/apt/keyrings

    log_command "Adding Kubernetes GPG key" \
        bash -c "curl -fsSL https://pkgs.k8s.io/core:/stable:/v${KUBECTL_MINOR_VERSION}/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg"

    log_command "Setting GPG key permissions" \
        chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

    log_command "Adding Kubernetes repository" \
        bash -c "echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${KUBECTL_MINOR_VERSION}/deb/ /' > /etc/apt/sources.list.d/kubernetes.list"
fi

# Update package lists with retry logic
apt_update

# ============================================================================
# kubectl Installation
# ============================================================================
log_message "Installing kubectl..."

# Install specific version if full version is provided, otherwise install latest from repository
if [[ "$KUBECTL_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    log_message "Installing specific kubectl version ${KUBECTL_VERSION}..."
    log_message "Installing kubectl package"
    apt_install kubectl="${KUBECTL_VERSION}-*"
else
    log_message "Installing kubectl package"
    apt_install kubectl
fi

# ============================================================================
# k9s Installation
# ============================================================================
log_message "Installing k9s ${K9S_VERSION}..."

# Detect architecture
ARCH=$(dpkg --print-architecture)

# Determine k9s filename and URL based on architecture
case "$ARCH" in
    amd64)
        K9S_FILENAME="k9s_Linux_amd64.tar.gz"
        ;;
    arm64)
        K9S_FILENAME="k9s_Linux_arm64.tar.gz"
        ;;
    *)
        log_warning "k9s not available for architecture $ARCH, skipping..."
        K9S_FILENAME=""
        ;;
esac

# Download and install k9s if supported architecture
if [ -n "$K9S_FILENAME" ]; then
    log_message "Fetching checksum for k9s ${K9S_VERSION} ${ARCH}..."

    # Fetch checksum dynamically from GitHub checksums.sha256 file
    K9S_CHECKSUMS_URL="https://github.com/derailed/k9s/releases/download/v${K9S_VERSION}/checksums.sha256"
    if ! K9S_CHECKSUM=$(fetch_github_checksums_txt "$K9S_CHECKSUMS_URL" "$K9S_FILENAME" 2>/dev/null); then
        log_error "Failed to fetch checksum for k9s ${K9S_VERSION}"
        log_error "Please verify version exists: https://github.com/derailed/k9s/releases/tag/v${K9S_VERSION}"
        log_feature_end
        exit 1
    fi

    log_message "✓ Fetched checksum from GitHub"

    # Download and verify k9s
    log_message "Downloading and verifying k9s for ${ARCH}..."
    download_and_extract \
        "https://github.com/derailed/k9s/releases/download/v${K9S_VERSION}/${K9S_FILENAME}" \
        "${K9S_CHECKSUM}" \
        "/usr/local/bin" \
        "k9s"
fi

# Verify k9s installation
if command -v k9s >/dev/null 2>&1; then
    log_command "Verifying k9s installation" \
        k9s version --short
else
    log_error "k9s installation failed"
    exit 1
fi

# ============================================================================
# Helm Installation
# ============================================================================
log_message "Installing Helm ${HELM_VERSION}..."

# Determine Helm filename based on architecture
case "$ARCH" in
    amd64)
        HELM_FILENAME="helm-v${HELM_VERSION}-linux-amd64.tar.gz"
        HELM_DIR="linux-amd64"
        ;;
    arm64)
        HELM_FILENAME="helm-v${HELM_VERSION}-linux-arm64.tar.gz"
        HELM_DIR="linux-arm64"
        ;;
    *)
        log_warning "Helm not available for architecture $ARCH, skipping..."
        HELM_FILENAME=""
        ;;
esac

# Download and install Helm if supported architecture
if [ -n "$HELM_FILENAME" ]; then
    BUILD_TEMP=$(create_secure_temp_dir)
    cd "$BUILD_TEMP"

    log_message "Calculating checksum for Helm ${HELM_VERSION} ${ARCH}..."
    log_message "(Helm doesn't publish plain checksums, calculating on download)"

    # Calculate checksum from download (Helm only has GPG-signed checksum files)
    HELM_URL="https://get.helm.sh/${HELM_FILENAME}"
    if ! HELM_CHECKSUM=$(calculate_checksum_sha256 "$HELM_URL" 2>/dev/null); then
        log_error "Failed to download and calculate checksum for Helm ${HELM_VERSION}"
        log_error "Please verify version exists: https://github.com/helm/helm/releases/tag/v${HELM_VERSION}"
        log_feature_end
        exit 1
    fi

    log_message "✓ Calculated checksum from download"

    # Download and verify Helm
    log_message "Downloading and verifying Helm for ${ARCH}..."
    download_and_extract \
        "$HELM_URL" \
        "${HELM_CHECKSUM}" \
        "." \
        ""  # Extract all files

    # Move helm binary to /usr/local/bin
    if [ -f "${HELM_DIR}/helm" ]; then
        log_command "Installing Helm binary" \
            mv "${HELM_DIR}/helm" /usr/local/bin/helm
    else
        log_error "Helm binary not found after extraction"
        log_feature_end
        exit 1
    fi

    cd /
fi

# Verify Helm installation
if command -v helm >/dev/null 2>&1; then
    log_command "Verifying Helm installation" \
        helm version --short
else
    log_error "Helm installation failed"
    exit 1
fi

# ============================================================================
# Krew Plugin Manager Installation
# ============================================================================
log_message "Installing kubectl plugin manager (krew) ${KREW_VERSION}..."

# Determine krew filename based on architecture
case "$ARCH" in
    amd64)
        KREW_FILENAME="krew-linux_amd64.tar.gz"
        ;;
    arm64)
        KREW_FILENAME="krew-linux_arm64.tar.gz"
        ;;
    *)
        log_warning "krew not available for architecture $ARCH, skipping..."
        KREW_FILENAME=""
        ;;
esac

# Download and install krew if supported architecture
if [ -n "$KREW_FILENAME" ]; then
    BUILD_TEMP=$(create_secure_temp_dir)
    cd "$BUILD_TEMP"

    log_message "Fetching checksum for krew ${KREW_VERSION} ${ARCH}..."

    # Fetch checksum dynamically from GitHub individual .sha256 file
    KREW_SHA256_URL="https://github.com/kubernetes-sigs/krew/releases/download/v${KREW_VERSION}/${KREW_FILENAME}.sha256"
    if ! KREW_CHECKSUM=$(fetch_github_sha256_file "$KREW_SHA256_URL" 2>/dev/null); then
        log_error "Failed to fetch checksum for krew ${KREW_VERSION}"
        log_error "Please verify version exists: https://github.com/kubernetes-sigs/krew/releases/tag/v${KREW_VERSION}"
        log_feature_end
        exit 1
    fi

    log_message "✓ Fetched checksum from GitHub"

    # Download and verify krew
    log_message "Downloading and verifying krew for ${ARCH}..."
    download_and_extract \
        "https://github.com/kubernetes-sigs/krew/releases/download/v${KREW_VERSION}/${KREW_FILENAME}" \
        "${KREW_CHECKSUM}" \
        "." \
        ""  # Extract all files

    # Find and install krew binary
    for krew_binary in ./krew-linux_*; do
        if [ -f "$krew_binary" ]; then
            log_command "Installing krew" \
                "$krew_binary" install krew
            break
        fi
    done

    cd /
fi

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

# kubectl auto-completion with validation
if command -v kubectl &> /dev/null; then
    COMPLETION_FILE="/tmp/kubectl-completion.$$.bash"
    if kubectl completion bash > "$COMPLETION_FILE" 2>/dev/null; then
        # Validate completion output before sourcing
        if [ -f "$COMPLETION_FILE" ] && \
           [ "$(wc -c < "$COMPLETION_FILE")" -lt 100000 ] && \
           ! grep -qE '(rm -rf|curl.*bash|wget.*bash|eval.*\$)' "$COMPLETION_FILE"; then
            # shellcheck disable=SC1090  # Dynamic source is validated
            source "$COMPLETION_FILE"
            complete -F __start_kubectl k
        fi
    fi
    rm -f "$COMPLETION_FILE"
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

# Log feature summary
log_feature_summary \
    --feature "Kubernetes Tools" \
    --tools "kubectl,k9s,helm,krew" \
    --paths "$HOME/.kube,$HOME/.krew" \
    --env "KUBECONFIG,KUBECTL_EXTERNAL_DIFF" \
    --commands "kubectl,k9s,helm,krew,k,kgp,kgs,kgd,kaf,k-logs,k-shell,k-events,k-resources" \
    --next-steps "Run 'test-kubernetes' to verify installation. Link kubeconfig or use 'kubectl config' to set up clusters. Install plugins with 'kubectl krew install <plugin>'."

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
